// One chat handed from this station to another of its workspace while both are up (handover.ts; replica/AGENTS.md).
// Driven by the station that has it (A), each step said to the one that takes it (B) by `handover.*`, each side's state
// in a file of its own (`handover/out/<id>.json`, `handover/in/<id>.json`), so that either started again goes on, or
// undoes what it put in. This file is the station it leaves; handover_in.mbt the station it goes to.
//
// A record is kept as the JSON it is written as (`Rec`): its fields in the order they were first given, as the
// TypeScript's object has them, so what is on the disk is what the TypeScript writes.

///|
pub let turn_wait_ms : Double = 600000.0

///|
pub let hash_most : Double = 268435456.0

///|
pub let floor_min : Double = 21474836480.0

///|
pub let floor_share : Double = 0.1

///|
pub let previous_limit_ms : Double = 40000.0

///|
let boot_slack_ms : Double = 60000.0

///|
/// What a move leaves free on the station it goes to, at the least.
pub fn floor_of(total : Double?) -> Double {
  let share = (total.unwrap_or(0.0) * floor_share).floor()
  if share > floor_min {
    share
  } else {
    floor_min
  }
}

///|
pub let chat_tables : Array[String] = [
  "threads", "sessions", "thread_sessions", "entries", "letters", "turns", "runtime_sessions", "closed_cards", "reads", "hidden_chats",
  "muted_chats", "kept_chats", "dismissed", "pins", "opened_chats", "deliveries", "usage", "usage_files", "session_usage",
]

///|
pub let marks_tables : Array[String] = ["reads", "hidden_chats", "muted_chats", "kept_chats", "dismissed"]

///|
pub let usage_tables : Array[String] = ["usage", "usage_files", "session_usage"]

///|
let after_shown : Array[String] = ["entries", "letters", "deliveries", "usage", "usage_files", "session_usage"]

///|
/// store/handover.ts `afterOf`: where the next page of `table` begins after `row`.
pub fn after_of(table : String, row : J) -> J {
  let f = (k : String) => at(row, k).unwrap_or(Null)
  match table {
    "entries" | "letters" | "closed_cards" => f("n")
    "reads" | "hidden_chats" | "muted_chats" | "kept_chats" | "pins" => f("viewer")
    "dismissed" => ja([f("viewer"), f("n")])
    "turns" => ja([f("started_at"), f("id")])
    "runtime_sessions" => f("id")
    "deliveries" => ja([f("thread"), f("n")])
    "usage" => ja([f("at"), f("id")])
    "usage_files" => f("path")
    _ => Null
  }
}

///|
/// store/handover.ts `newCtx`.
pub fn new_ctx(c : J) -> J {
  merged(
    c,
    jo([
      ("threads", jo([])),
      ("made", jo([("sessions", ja([])), ("entries", ja([])), ("letters", ja([])), ("members", ja([])), ("rows", jo([]))])),
      ("counts", jo([("sessions", ji(0)), ("entries", jo([])), ("letters", jo([])), ("rows", jo([]))])),
    ]),
  )
}

///|
/// move/module.ts `UNANSWERED`: what the transport says of a station that did not answer.
pub fn unanswered(message : String) -> Bool {
  let m = message.to_lower()
  if m.contains("answered nothing") || m.contains("got no answer") || m.contains("timed out") || m.contains("station unreachable") {
    return true
  }
  for lead in ["connection ", "stream "] {
    let ends = if lead == "connection " { ["gone", "lost", "closed", "reset"] } else { ["reset", "closed", "stopped"] }
    for e in ends {
      if m.contains(lead + e) || m.contains(lead + "was " + e) {
        return true
      }
    }
  }
  false
}

///|
/// Whether it is move/module.ts's `Said` (its `AskAgain` and `Gone` too).
pub fn is_said(e : Error) -> Bool {
  let k = kind_of(e)
  k == "Said" || k == "AskAgain" || k == "Gone"
}

///|
/// move/module.ts `sayOf`: what an item's failure says to people.
pub fn say_of(w : World, e : Error, what : String) -> String {
  let message = message_of(e)
  if is_said(e) || is_refused(e) {
    return message
  }
  w.warn("move", "an item failed: the error, said to people in the station's words", jo([("item", js(what)), ("error", js(message))]))
  w.tr(if unanswered(message) { "station.move.why.unanswered" } else { "station.move.why.failedHere" })
}

///|
/// A record of a hand-over, as the JSON it is written as.
pub struct Rec {
  mut j : J
}

///|
pub fn Rec::s(self : Rec, k : String) -> String {
  text_at(self.j, k)
}

///|
pub fn Rec::so(self : Rec, k : String) -> String? {
  str_at(self.j, k)
}

///|
pub fn Rec::n(self : Rec, k : String) -> Double {
  num_at(self.j, k).unwrap_or(0.0)
}

///|
pub fn Rec::b(self : Rec, k : String) -> Bool {
  yes_at(self.j, k)
}

///|
pub fn Rec::get(self : Rec, k : String) -> J? {
  at(self.j, k)
}

///|
pub fn Rec::set(self : Rec, k : String, v : J) -> Unit {
  self.j = set(self.j, k, v)
}

///|
pub fn Rec::del(self : Rec, k : String) -> Unit {
  self.j = unset(self.j, k)
}

///|
pub fn Rec::keys(self : Rec) -> Array[String] {
  strings_of(at(self.j, "keys"))
}

///|
/// What a hand-over's steps took (ms), from when each began to when the next did, the last to `end`; and the whole.
fn took_of(began : J?, end : Double) -> (J, Double) {
  let steps = entries(began)
  let ms = []
  for n, step in steps {
    let at = num_of(Some(step.1)).unwrap_or(0.0)
    let next = if n + 1 < steps.length() { num_of(Some(steps[n + 1].1)).unwrap_or(0.0) } else { end }
    ms.push((step.0, jn(js_round(next - at))))
  }
  let total = if steps.length() == 0 { 0.0 } else { js_round(end - num_of(Some(steps[0].1)).unwrap_or(0.0)) }
  (jo(ms), total)
}

///|
/// The steps asked of another station that are told back, and those it asks of this one (move/told.ts).
pub(all) struct ToldSteps {
  asked : async (String, String, () -> J, ((J) -> Unit)?) -> J
  run : async (String, String, async () -> J, (async () -> J)?) -> J
  let_go : (String, String, String) -> Unit
  settle : async () -> Unit
}

///|
/// What reads the sessions of a plan (handover.ts `SessionReads`).
pub struct SessionReads {
  session : async (String) -> J?
  home_members : async (String) -> Array[String]?
  ran_on : async (String) -> Array[String]
}

///|
/// What Handover is given (handover.ts `HandoverDeps`): the store, the hub, the connects, the jobs and the accounts are
/// the station's parts, asked by name (`store.getSession`, `hub.holdChat`...).
pub(all) struct HandoverDeps {
  data : String
  here : () -> String?
  home : () -> String?
  roster : (String) -> Array[Member]?
  /// Whether the station has its workspace's connects (none: a rig's).
  connects : Bool
  repos_dir : String
  room : async () -> (Double?, Double?)
  has_git : async () -> Bool
  flush : (async (String) -> Unit)?
  boot : () -> Double
  git : (async (String, Array[String]) -> String)?
  lack_most : Int
  hash_most : Double
  pack_files : Int?
  pack_bytes : Double?
  work : Work
  told : ToldSteps
  hold : (() -> () -> Unit)?
  fail : (async (String) -> Unit)?
  previous : Later[Unit]?
  previous_pid : Double?
}

///|
pub struct Handover {
  w : World
  d : HandoverDeps
  outs : Map[String, Rec]
  outs_of : Map[String, Array[Rec]]
  ins : Map[String, Rec]
  ins_of : Map[String, Array[Rec]]
  coming_ins : Array[Rec]
  owed_outs : Array[Rec]
  looked : Map[String, Int]
  in_held : Map[String, () -> Unit]
  in_work : Map[String, Run]
  dropping : Map[String, Bool]
  runs : Map[String, Run]
  again : Map[String, () -> Unit]
  tries : Map[String, Int]
  drops : Map[String, (Run, Run)]
  mut closed : Bool
  loaded : Later[Unit]
  mut ready : Bool
  mut held_at_load : Array[String]
  waiting_turn : Map[String, Bool]
  mending : Map[String, Bool]
  unmended : Array[Rec]
  unsure : Array[String]
  rebooted : Array[String]
  asking : Map[String, Bool]
  mut said_still : Bool
  settled_in : Map[String, Array[() -> Unit]]
  usage_caught_up : Map[String, Bool]
  usage_runs : Map[String, Run]
  mut usage_synced : J?
  mut usage_saving : Run
  usage_again : Map[String, Bool]
}

///|
fn hdir(fs : Fs, data : String) -> String {
  fs.join([data, "replica", "handover"])
}

///|
fn out_file(fs : Fs, data : String, id : String) -> String {
  fs.join([hdir(fs, data), "out", "\{id}.json"])
}

///|
fn in_file(fs : Fs, data : String, id : String) -> String {
  fs.join([hdir(fs, data), "in", "\{id}.json"])
}

///|
fn in_files(fs : Fs, data : String, id : String) -> String {
  fs.join([hdir(fs, data), "in", id, "files"])
}

///|
fn end_file(fs : Fs, data : String, id : String) -> String {
  fs.join([hdir(fs, data), "out", "\{id}.end"])
}

///|
fn in_made(fs : Fs, data : String, id : String) -> String {
  fs.join([hdir(fs, data), "in", id, "made.txt"])
}

///|
fn in_aside(fs : Fs, data : String, id : String) -> String {
  fs.join([hdir(fs, data), "in", id, "aside"])
}

///|
fn in_gits(fs : Fs, data : String, id : String) -> String {
  fs.join([hdir(fs, data), "in", id, "gits.jsonl"])
}

///|
fn scratch_of(fs : Fs, data : String, id : String) -> String {
  fs.join([hdir(fs, data), "out", id])
}

///|
fn usage_synced_file(fs : Fs, data : String) -> String {
  fs.join([hdir(fs, data), "usage-synced.json"])
}

///|
/// The one end of hand-over `id`, whichever process asks first: `want` where none was decided yet, else the one that
/// was (a file linked into place).
async fn decided(fs : Fs, data : String, id : String, want : String) -> String {
  let path = end_file(fs, data, id)
  fs.mkdirs(fs.dirname(path))
  let tmp = "\{path}.\{fs.random_hex(4)}.tmp"
  fs.write_text(tmp, want)
  let out = try {
    if fs.link(tmp, path) {
      want
    } else {
      let was = js_trim(fs.read_text(path).unwrap_or(""))
      if was == "gone" {
        "gone"
      } else {
        "failed"
      }
    }
  } catch {
    e => {
      fs.rm_f(tmp)
      raise e
    }
  }
  fs.rm_f(tmp)
  out
}

///|
async fn read_all(fs : Fs, at_dir : String) -> Array[J] {
  let out = []
  for name in fs.names(at_dir) {
    if !name.has_suffix(".json") {
      continue
    }
    match fs.read_json(fs.join([at_dir, name])) {
      Some(v) => out.push(v)
      None => ()
    }
  }
  out
}

///|
/// The key of a told step a request names (move/told.ts).
fn told_key(request : J) -> String? {
  match str_at(request, "told") {
    Some(t) if t.length() > 0 && t.length() <= 300 => Some(t)
    _ => None
  }
}

///|
fn unchecked_of(answer : J) -> Array[String] {
  strings_of(at(answer, "unchecked"))
}

///|
let write_failed : Array[String] = ["ENOSPC", "EDQUOT", "EROFS"]

///|
/// Still.fail's own chats' connect, and the one of before.
fn is_internal(c : String) -> Bool {
  c == "ember" || c == "chat"
}

///|
/// Whether a connect's chats are routed to the station a chat of it runs on.
fn routed(k : J) -> Bool {
  let mode = text_at(k, "mode")
  let kind = text_at(k, "kind")
  mode != "single-session" && (kind == "slack" || kind == "feishu")
}

///|
pub let stillfail_surface = "chat"

///|
/// What a chat handed here is told once, as its next turn starts.
pub fn moved_here(fs : Fs, from : String, workspace : String, from_data : String, to_data : String) -> String {
  let lines = ["<chat-moved>This chat was handed here from station \{from}: it goes on on this station."]
  if from_data != "" && from_data != to_data {
    lines.push(
      "Its files were under \{from_data} and are under \{to_data} now: a path you noted under the old one is the same under the new one (your working directory is \{moved(fs, workspace, from_data, to_data)}).",
    )
  }
  lines.push("Its background jobs are started again here as they move; nobody asked anything of you by this, and it is said once.</chat-moved>")
  lines.join("\n")
}

///|
/// The hand-over's id: of when, its sessions and the station it goes to, and a part of its own.
pub async fn handover_id(fs : Fs, keys : Array[String], to : String, at_ms : Double) -> String {
  let first = keys.get(0).unwrap_or("")
  let hex = @hex.encode(@utf8.encode(first))
  "\{base36(at_ms)}-\{head_of(hex, 24)}-\{head_of(to, 8)}-\{fs.random_hex(4)}"
}

///|
/// `n.toString(36)` of a whole non-negative number.
pub fn base36(n : Double) -> String {
  if n < 1.0 {
    return "0"
  }
  let digits = "0123456789abcdefghijklmnopqrstuvwxyz"
  let out = []
  let mut x = n.floor()
  while x >= 1.0 {
    let d = (x - (x / 36.0).floor() * 36.0).to_int()
    out.push(digits.unsafe_charcode_at(d))
    x = (x / 36.0).floor()
  }
  let s = StringBuilder::new()
  for i = out.length() - 1; i >= 0; i = i - 1 {
    s.write_char(out[i].unsafe_to_char())
  }
  s.to_string()
}

///|
pub async fn Handover::new(w : World, d : HandoverDeps) -> Handover {
  let h : Handover = {
    w,
    d,
    outs: {},
    outs_of: {},
    ins: {},
    ins_of: {},
    coming_ins: [],
    owed_outs: [],
    looked: {},
    in_held: {},
    in_work: {},
    dropping: {},
    runs: {},
    again: {},
    tries: {},
    drops: {},
    closed: false,
    loaded: Later::new(),
    ready: d.previous is None,
    held_at_load: [],
    waiting_turn: {},
    mending: {},
    unmended: [],
    unsure: [],
    rebooted: [],
    asking: {},
    said_still: false,
    settled_in: {},
    usage_caught_up: {},
    usage_runs: {},
    usage_synced: None,
    usage_saving: Run::over(),
    usage_again: {},
  }
  h.load()
  match d.previous {
    None => h.loaded.resolve(())
    Some(p) =>
      w.go(async fn() {
        p.wait() catch {
          _ => ()
        }
        h.reload()
        h.loaded.resolve(())
        h.ready = true
      })
  }
  h
}

///|
pub async fn Handover::store(self : Handover, name : String, args : Array[J]) -> J {
  self.w.part("store." + name, args)
}

///|
pub async fn Handover::hub(self : Handover, name : String, args : Array[J]) -> J {
  self.w.part("hub." + name, args)
}

///|
fn remove_rec(xs : Array[Rec], r : Rec) -> Unit {
  match xs.search_by(x => physical_equal(x, r)) {
    Some(i) => ignore(xs.remove(i))
    None => ()
  }
}

///|
fn has_rec(xs : Array[Rec], r : Rec) -> Bool {
  xs.iter().any(x => physical_equal(x, r))
}

///|
fn Handover::reads(self : Handover) -> SessionReads {
  {
    session: async fn(k) {
      match self.store("getSession", [js(k)]) {
        Null => None
        v => Some(v)
      }
    },
    home_members: async fn(k) {
      let home = self.store("homeChat", [js(k)])
      if home is Null || text_at(home, "surface") != stillfail_surface {
        return None
      }
      Some(items(Some(self.store("threadSessions", [at(home, "id").unwrap_or(Null)]))).map(m => text_at(m, "session")))
    },
    ran_on: async fn(k) {
      let rows = items(Some(self.store("chatPage", [js("runtime_sessions"), js(k), Null, ji(500)])))
      uniq(rows.filter_map(r => str_at(r, "profile")))
    },
  }
}

///|
/// The records read: each hand-over's chats held again as it stood.
async fn Handover::load(self : Handover) -> Unit {
  let fs = self.w.fs
  let d = self.d
  for o in read_all(fs, fs.join([hdir(fs, d.data), "out"])) {
    self.keep_out({ j: o })
  }
  let boot = (d.boot)()
  for v in read_all(fs, fs.join([hdir(fs, d.data), "in"])) {
    let i : Rec = { j: v }
    if i.s("step") == "coming" {
      match self.store("importCtx", [js(i.s("id"))]) {
        Null => ()
        ctx => i.set("ctx", ctx)
      }
    }
    let dropping = i.b("dropping")
    let rebooted = i.s("step") == "coming" &&
      !dropping &&
      (match i.get("boot") {
        Some(Num(b)) => (b - boot).abs() > boot_slack_ms
        _ => false
      })
    if rebooted {
      self.rebooted.push(i.s("id"))
      self.dropping[i.s("id")] = true
    } else if i.s("step") == "coming" && !dropping {
      self.unsure.push(i.s("id"))
    }
    if i.s("step") == "coming" && dropping {
      self.dropping[i.s("id")] = true
    }
    self.keep_in(i)
    self.hold_in(i)
  }
  let held : Array[String] = []
  for o in self.every_out("start") {
    let step = o.s("step")
    if (step == "held" || step == "files" || step == "rows") && !(o.get("held") is Some(Bool(false))) {
      for key in o.keys() {
        if !held.contains(key) {
          held.push(key)
        }
      }
    }
  }
  for o in self.every_out("start") {
    for key in self.not_off(o) {
      if !held.contains(key) {
        held.push(key)
      }
    }
  }
  for key in held {
    let latest = match self.outs_of.get(key) {
      Some(xs) if xs.length() > 0 => Some(xs[0])
      _ => None
    }
    let name = match latest {
      Some(o) => if o.s("toName") != "" { o.s("toName") } else { head_of(o.s("to"), 8) }
      None => ""
    }
    self.w.go(async fn() { ignore(self.hub("holdChat", [js(key), js("moving to \{name}")])) })
  }
  self.held_at_load = held
  self.unmended.clear()
  for o in self.outs.values().collect() {
    let step = o.s("step")
    if o.n("v") == 2.0 && (step == "failed" || step == "gone") && !o.b("shown") && !o.b("ended") {
      let mut any = false
      for k in o.keys() {
        let latest = match self.outs_of.get(k) {
          Some(xs) if xs.length() > 0 => physical_equal(xs[0], o)
          _ => false
        }
        if latest && text_at(self.store("handedTo", [js(k)]), "station") == o.s("to") {
          any = true
          break
        }
      }
      if any {
        self.unmended.push(o)
      }
    }
  }
}

///|
/// The records read again, the process before gone.
async fn Handover::reload(self : Handover) -> Unit {
  let before = self.held_at_load
  for f in self.in_held.values() {
    f()
  }
  self.in_held.clear()
  self.outs.clear()
  self.outs_of.clear()
  self.ins.clear()
  self.ins_of.clear()
  self.coming_ins.clear()
  self.owed_outs.clear()
  self.unsure.clear()
  self.dropping.clear()
  self.rebooted.clear()
  self.load()
  for key in before {
    if !self.held_at_load.contains(key) {
      ignore(self.hub("releaseChat", [js(key)]))
    }
  }
}

///|
/// The sessions of `o`, gone, still in sight here.
async fn Handover::not_off(self : Handover, o : Rec) -> Array[String] {
  if o.b("ended") || (o.s("step") != "gone" && o.s("step") != "done") {
    return []
  }
  let out = []
  for k in o.keys() {
    if self.store("getSession", [js(k)]) is Null {
      continue
    }
    match self.store("sessionWs", [js(k)]) {
      Str(u) if @jsjson.text(u).has_prefix("handed:") => continue
      _ => ()
    }
    if o.n("v") == 2.0 || !self.came_back(o, k) {
      out.push(k)
    }
  }
  out
}

///|
/// Whether chat `k` came here since `o` took it away, from where it went.
fn Handover::came_back(self : Handover, o : Rec, k : String) -> Bool {
  self.ins_at([k], "cameBack").iter().any(i => i.s("step") == "shown" && i.s("origin") == o.s("to") && i.n("at") >= o.n("at"))
}

///|
pub async fn Handover::start(self : Handover) -> Unit {
  self.loaded.wait()
  let fs = self.w.fs
  for o in self.every_out("start") {
    let step = o.s("step")
    if step != "held" && step != "files" && step != "rows" {
      continue
    }
    if !(o.get("counts") is (Some(Null) | None)) && decided(fs, self.d.data, o.s("id"), "failed") == "gone" {
      o.set("step", js("gone"))
      o.set("error", Null)
      self.save(o)
      self.w.info("handover", "a chat went as this station stopped: it went", jo([("id", js(o.s("id"))), ("to", js(o.s("to")))]))
    } else {
      let who = if o.s("toName") != "" { o.s("toName") } else { head_of(o.s("to"), 12) }
      self.fail(o, self.w.tr("station.move.restartedMidway", args=[("station", who)]))
    }
  }
  for id in self.rebooted.copy() {
    guard self.ins.get(id) is Some(i) else { continue }
    self.w.warn(
      "handover",
      "a chat coming here was begun before this machine started again: what it took may not be on the drive: dropped here",
      jo([("id", js(i.s("id"))), ("from", js(head_of(i.s("origin"), 12)))]),
    )
    self.drop_soon(i).0.wait()
  }
  self.rebooted.clear()
  for i in self.coming_ins.copy() {
    if i.b("dropping") {
      ignore(self.drop_soon(i))
    }
  }
  for id in self.unsure.copy() {
    match self.ins.get(id) {
      Some(i) => self.ask_still(i)
      None => ()
    }
  }
  for name in fs.names(fs.join([hdir(fs, self.d.data), "in"])) {
    if name.has_prefix(".gone-") {
      let path = fs.join([hdir(fs, self.d.data), "in", name])
      self.w.go(async fn() {
        fs.rm_rf(path) catch {
          _ => ()
        }
      })
    }
  }
  for o in self.every_out("start") {
    let off = self.not_off(o)
    if off.length() == 0 {
      continue
    }
    ignore(self.store("goneTo", [jstrs(off), js(o.s("to")), o.get("there").unwrap_or(jo([]))]))
    ignore(self.w.part("went", [jstrs(off)]))
    if !o.b("shown") {
      continue
    }
    ignore(self.store("shownThere", [jstrs(off), jopt((self.d.home)())]))
    for k in off {
      ignore(self.hub("releaseChat", [js(k)]))
    }
  }
  for o in self.every_out("start") {
    if o.s("step") == "gone" && o.n("v") != 2.0 && o.keys().iter().all(k => self.came_back(o, k)) {
      o.set("step", js("done"))
      o.set("ended", jb(true))
      self.save(o)
    } else if o.s("step") == "gone" || (o.s("step") == "failed" && o.b("dropOwed")) {
      self.go(o)
    }
  }
  self.w.go(async fn() { self.mend(None) })
  self.sync_handed_usage(None)
}

///|
/// Once the process before is gone and the records read again: PREVIOUS_LIMIT_MS at most, then refused in words.
pub async fn Handover::loaded_within(self : Handover) -> Unit {
  if self.ready {
    return
  }
  let late : Later[Bool] = Later::new()
  // timer: a deadline for the process before to be gone
  let cancel = self.w.after(previous_limit_ms, () => late.resolve(false))
  self.w.go(async fn() {
    self.loaded.wait()
    late.resolve(true)
  })
  let came = late.wait()
  cancel()
  if came {
    return
  }
  if !self.said_still {
    self.said_still = true
    self.w.warn(
      "handover",
      "the station process before this one is still there: moves are refused until it is gone",
      jo([("pid", opt_num(self.d.previous_pid)), ("waitedMs", jn(previous_limit_ms))]),
    )
  }
  raise refused(self.w.tr("station.move.previousStill"))
}

///|
/// The chats said gone whose latest hand-over from here failed and was never shown there: asked of that station.
async fn Handover::mend(self : Handover, only : String?) -> Unit {
  for o in self.unmended.copy() {
    if (only is Some(s) && o.s("to") != s) || self.mending.contains(o.s("id")) {
      continue
    }
    let keys = []
    for k in o.keys() {
      let latest = match self.outs_of.get(k) {
        Some(xs) if xs.length() > 0 => physical_equal(xs[0], o)
        _ => false
      }
      if latest && text_at(self.store("handedTo", [js(k)]), "station") == o.s("to") {
        keys.push(k)
      }
    }
    if keys.length() == 0 {
      remove_rec(self.unmended, o)
      continue
    }
    self.mending[o.s("id")] = true
    try {
      let mut skip = false
      if o.s("step") == "gone" {
        let held = self.w.ask(
          o.s("to"),
          jo([("method", js("handover.held")), ("workspace", js(o.s("ws"))), ("origin", jopt((self.d.here)())), ("id", js(o.s("id")))]),
        )
        if !(at(held, "held") is Some(Bool(false))) {
          if at(held, "held") is Some(Bool(true)) {
            remove_rec(self.unmended, o)
          }
          skip = true
        }
      }
      if !skip {
        let answer = self.w.ask(o.s("to"), jo([("method", js("move.chats.live")), ("keys", jstrs(keys))]))
        let live = strings_of(at(answer, "live"))
        let there = keys.filter(k => live.contains(k))
        let here = keys.filter(k => !live.contains(k))
        if there.length() > 0 {
          o.set("step", js("done"))
          o.set("shown", jb(true))
          o.set("ended", jb(true))
          o.set("error", Null)
          o.set("dropOwed", jb(false))
          self.save(o)
          ignore(self.store("shownThere", [jstrs(there), jopt((self.d.home)())]))
          for k in there {
            ignore(self.hub("releaseChat", [js(k)]))
          }
          self.w.info(
            "handover",
            "a chat said gone whose hand-over failed here is there after all: it went",
            jo([("id", js(o.s("id"))), ("to", js(o.s("to"))), ("keys", ji(there.length()))]),
          )
        }
        if here.length() > 0 {
          if o.s("step") == "gone" && there.length() == 0 {
            match self.again.get(o.s("id")) {
              Some(f) => f()
              None => ()
            }
            self.again.remove(o.s("id"))
            let who = if o.s("toName") != "" { o.s("toName") } else { head_of(o.s("to"), 12) }
            o.set("step", js("failed"))
            o.set("error", js(self.w.tr("station.move.restartedMidway", args=[("station", who)])))
            o.set("ended", jb(true))
            o.set("dropOwed", jb(false))
            self.save(o)
            for j in items(o.get("jobs")) {
              ignore(self.w.part("jobs.start", [j])) catch {
                e =>
                  self.w.warn("handover", "a job of a chat taken back not started again", jo([("job", at(j, "name").unwrap_or(Null)), ("error", js(message_of(e)))]))
              }
            }
          }
          let back = strings_of(Some(self.store("notGone", [jstrs(here), js(o.s("to"))])))
          for k in back {
            ignore(self.hub("releaseChat", [js(k)]))
          }
          self.w.warn(
            "handover",
            "a chat said gone whose hand-over failed is not there: in sight here again",
            jo([("id", js(o.s("id"))), ("to", js(o.s("to"))), ("keys", ji(back.length()))]),
          )
        }
        remove_rec(self.unmended, o)
      }
    } catch {
      e =>
        self.w.info(
          "handover",
          "a chat said gone whose hand-over failed: its station not asked yet",
          jo([("id", js(o.s("id"))), ("to", js(o.s("to"))), ("error", js(message_of(e)))]),
        )
    }
    self.mending.remove(o.s("id"))
  }
}

///|
pub async fn Handover::close(self : Handover) -> Unit {
  self.closed = true
  for f in self.in_held.values() {
    f()
  }
  self.in_held.clear()
  for list in self.settled_in.values() {
    for f in list {
      f()
    }
  }
  self.settled_in.clear()
  for f in self.again.values() {
    f()
  }
  self.again.clear()
  for r in [..self.runs.values(), ..self.usage_runs.values()] {
    r.settled()
  }
}

///|
/// What is under way brought to rest (a test's).
pub async fn Handover::settle(self : Handover) -> Unit {
  while true {
    (self.d.told.settle)()
    if self.runs.length() == 0 && self.drops.length() == 0 && self.usage_runs.length() == 0 {
      return
    }
    for r in [..self.runs.values(), ..self.usage_runs.values(), ..self.drops.values().map(d => d.1)] {
      r.settled()
    }
  }
}

///|
/// The hand-overs from here, the latest of each chat first.
pub fn Handover::outs_list(self : Handover) -> Array[J] {
  let all = self.outs.values().collect()
  all.sort_by((a, b) => {
    let d = b.n("at") - a.n("at")
    if d < 0.0 {
      -1
    } else if d > 0.0 {
      1
    } else {
      0
    }
  })
  all.map(o => o.j)
}

///|
pub fn Handover::ins_list(self : Handover) -> Array[J] {
  self.ins.values().map(i => i.j).collect()
}

///|
fn Handover::keep_out(self : Handover, o : Rec) -> Unit {
  self.outs[o.s("id")] = o
  self.owed_now(o)
  for k in o.keys() {
    let list = self.outs_of.get(k).unwrap_or([]).filter(x => x.s("id") != o.s("id"))
    let at = list.search_by(x => x.n("at") < o.n("at"))
    match at {
      Some(i) => list.insert(i, o)
      None => list.push(o)
    }
    self.outs_of[k] = list
  }
}

///|
fn Handover::keep_in(self : Handover, i : Rec) -> Unit {
  self.ins[i.s("id")] = i
  self.coming_now(i)
  for k in i.keys() {
    let list = self.ins_of.get(k).unwrap_or([])
    if !has_rec(list, i) {
      list.push(i)
    }
    self.ins_of[k] = list
  }
}

///|
fn Handover::forget_in(self : Handover, i : Rec) -> Unit {
  self.ins.remove(i.s("id"))
  remove_rec(self.coming_ins, i)
  for k in i.keys() {
    let list = self.ins_of.get(k).unwrap_or([]).filter(x => x.s("id") != i.s("id"))
    if list.length() > 0 {
      self.ins_of[k] = list
    } else {
      self.ins_of.remove(k)
    }
  }
}

///|
fn Handover::coming_now(self : Handover, i : Rec) -> Unit {
  if i.s("step") == "coming" {
    if !has_rec(self.coming_ins, i) {
      self.coming_ins.push(i)
    }
  } else {
    remove_rec(self.coming_ins, i)
  }
}

///|
fn Handover::every_out(self : Handover, kind : String) -> Array[Rec] {
  self.look(kind, self.outs.length())
  self.outs.values().collect()
}

///|
fn Handover::owed_now(self : Handover, o : Rec) -> Unit {
  if o.s("step") == "gone" || o.b("dropOwed") {
    if !has_rec(self.owed_outs, o) {
      self.owed_outs.push(o)
    }
  } else {
    remove_rec(self.owed_outs, o)
  }
}

///|
fn Handover::forget_out(self : Handover, o : Rec) -> Unit {
  self.outs.remove(o.s("id"))
  remove_rec(self.owed_outs, o)
  for k in o.keys() {
    let list = self.outs_of.get(k).unwrap_or([]).filter(x => x.s("id") != o.s("id"))
    if list.length() > 0 {
      self.outs_of[k] = list
    } else {
      self.outs_of.remove(k)
    }
  }
}

///|
fn Handover::outs_at(self : Handover, keys : Array[String], kind : String) -> Array[Rec] {
  let out : Array[Rec] = []
  for k in keys {
    for o in self.outs_of.get(k).unwrap_or([]) {
      self.look(kind, 1)
      if !has_rec(out, o) {
        out.push(o)
      }
    }
  }
  out
}

///|
fn Handover::ins_at(self : Handover, keys : Array[String], kind : String) -> Array[Rec] {
  let out : Array[Rec] = []
  for k in keys {
    for i in self.ins_of.get(k).unwrap_or([]) {
      self.look(kind, 1)
      if !has_rec(out, i) {
        out.push(i)
      }
    }
  }
  out
}

///|
fn Handover::spent(self : Handover, i : Rec?, kind : String, t0 : Double) -> Unit {
  guard i is Some(i) else { return }
  let spent = match i.get("spent") {
    Some(Obj(_) as s) => s
    _ => jo([])
  }
  let was = num_at(spent, kind).unwrap_or(0.0)
  i.set("spent", set(spent, kind, jn(was + js_round(self.w.now() - t0))))
}

///|
fn Handover::mark(self : Handover, o : Rec, step : String) -> Unit {
  let began = match o.get("began") {
    Some(Obj(_) as b) => b
    _ => jo([])
  }
  o.set("began", set(began, step, jn(self.w.now())))
}

///|
/// How many records what was done so far looked at, by what looked.
pub fn Handover::looked_at(self : Handover) -> J {
  jo(self.looked.iter().map(e => (e.0, ji(e.1))).collect())
}

///|
fn Handover::look(self : Handover, kind : String, n : Int) -> Unit {
  if n > 0 {
    self.looked[kind] = self.looked.get(kind).unwrap_or(0) + n
  }
}

///|
/// The latest hand-over of session `key` from here.
pub fn Handover::out_of(self : Handover, key : String) -> J? {
  match self.outs_of.get(key) {
    Some(xs) if xs.length() > 0 => Some(xs[0].j)
    _ => None
  }
}

///|
pub fn Handover::waits_for_turn(self : Handover, id : String) -> Bool {
  self.waiting_turn.contains(id)
}

// ── the station it leaves ──

///|
/// The move under way asked to stop: each hand-over not gone yet gives up at its next step.
pub fn Handover::abandon(self : Handover) -> Unit {
  for o in self.every_out("abandon") {
    let step = o.s("step")
    if step != "files" && step != "held" && step != "rows" {
      continue
    }
    o.set("abandoned", jb(true))
    match o.so("waitsOn") {
      Some(k) => (self.d.told.let_go)(o.s("to"), k, self.w.tr("station.move.why.abandoned"))
      None => ()
    }
  }
}

///|
async fn Handover::wait_step(self : Handover, o : Rec, key : String, make : () -> J, progress? : ((J) -> Unit)? = None) -> J {
  self.given(o)
  o.set("waitsOn", js(key))
  let out = (self.d.told.asked)(o.s("to"), key, make, progress) catch {
    e => {
      if o.so("waitsOn") == Some(key) {
        o.del("waitsOn")
      }
      raise e
    }
  }
  if o.so("waitsOn") == Some(key) {
    o.del("waitsOn")
  }
  out
}

///|
fn Handover::given(self : Handover, o : Rec) -> Unit raise {
  if o.b("abandoned") {
    raise said(self.w.tr("station.move.why.abandoned"))
  }
}

///|
/// The sessions handed over with `key`: those that share its still.fail home chat.
pub async fn Handover::together(self : Handover, key : String, reads? : SessionReads? = None) -> Array[String] {
  let r = reads.unwrap_or(self.reads())
  let keys = [key]
  for m in (r.home_members)(key).unwrap_or([]) {
    if !keys.contains(m) {
      keys.push(m)
    }
  }
  keys.sort_by(js_cmp)
  keys
}

///|
/// The chat session `key` goes with, by the first of its keys.
pub async fn Handover::chat_of(self : Handover, key : String) -> String {
  let threads = items(Some(self.store("sessionThreads", [js(key), ji(64)])))
  let home = threads
    .iter()
    .find_first(m => {
      let t = at(m, "thread").unwrap_or(Null)
      text_at(t, "surface") == stillfail_surface && !(at(t, "home") is (Some(Null) | None)) && str_at(t, "home") != Some(key)
    })
    .map(m => text_at(at(m, "thread").unwrap_or(Null), "home"))
  self.together(home.unwrap_or(key)).get(0).unwrap_or(key)
}

///|
async fn Handover::chat_name(self : Handover, key : String) -> String {
  match str_at(self.store("getSession", [js(key)]), "title") {
    Some(t) => t
    None => if key.has_prefix("chat:") { key.unsafe_substring(start=5, end=key.length()) } else { key }
  }
}

///|
fn Handover::why(self : Handover, key : String, args? : Array[(String, String)] = []) -> String {
  self.w.tr("station.move.why.\{key}", args~)
}

///|
/// Why chat `key` cannot be handed to `to` now, in words that say what to do (None: it can).
pub async fn Handover::check(
  self : Handover,
  key : String,
  to : String,
  ignore_files? : Bool = false,
  planning? : Bool = false,
  stopped_for? : J? = None,
  reads? : SessionReads? = None,
) -> String? {
  let r = reads.unwrap_or(self.reads())
  let here = (self.d.here)()
  let row = (r.session)(key)
  guard here is Some(here) && row is Some(row) else { return Some(self.why("noSuchChat")) }
  let ws = str_of(Some(self.hub("wsOf", [row])))
  let row_ws = str_at(row, "ws").unwrap_or("")
  guard ws is Some(ws) && !row_ws.has_prefix("handed:") && !row_ws.has_prefix("coming:") else {
    return Some(self.why("notInWorkspaceNow"))
  }
  if !is_workspace(ws) || !is_station(to) || to == here {
    return Some(self.why("nameAnother"))
  }
  let roster = (self.d.roster)(ws).unwrap_or([])
  guard roster.search_by(s => s.id == to) is Some(ti) else { return Some(self.why("notOfWorkspace")) }
  let target = roster[ti]
  if target.tasks {
    return Some(self.why("tasksOnly", args=[("station", target.name)]))
  }
  let busy = self.outs_at([key], "check").iter().find_first(o => {
    let s = o.s("step")
    s == "held" || s == "files" || s == "rows" || s == "gone"
  })
  match busy {
    Some(b) =>
      return Some(
        if b.s("step") == "gone" {
          self.why("goingAlready", args=[("station", if b.s("toName") != "" { b.s("toName") } else { head_of(b.s("to"), 8) })])
        } else {
          self.why("handingAlready")
        },
      )
    None => ()
  }
  let stopped_module = match stopped_for {
    Some(Obj(_) as s) => text_at(s, "module")
    _ => ""
  }
  for k in self.together(key, reads=Some(r)) {
    guard (r.session)(k) is Some(s) else { continue }
    let connect = text_at(s, "connect")
    let kind = if is_internal(connect) || !self.d.connects {
      None
    } else {
      match self.w.part("connects.kindOf", [js(connect)]) {
        Null => None
        k => Some(k)
      }
    }
    match kind {
      Some(kind) if !routed(kind) && !planning && stopped_module != "connects" => {
        let runs = str_of(Some(self.w.part("connects.runsOn", [js(connect)])))
        if runs != Some(to) {
          let kind_words = if text_at(kind, "mode") == "single-session" { self.why("oneSession") } else { text_at(kind, "kind") }
          return Some(self.why("connectFirst", args=[("chat", self.chat_name(k)), ("connect", connect), ("kind", kind_words)]))
        }
      }
      _ => ()
    }
    if !ignore_files && at(s, "archivedAt") is Some(Null) && !text_at(s, "workspace").has_prefix(self.w.fs.join([self.d.data, "sessions"])) {
      return Some(self.why("filesOutside", args=[("chat", self.chat_name(k)), ("dir", text_at(s, "workspace"))]))
    }
  }
  None
}

///|
/// The accounts sessions `keys` run on, as they are known across the workspace (None: this machine's own).
pub async fn Handover::accounts_of(self : Handover, keys : Array[String], reads? : SessionReads? = None) -> Array[(String, J)] {
  let r = reads.unwrap_or(self.reads())
  let out : Array[(String, J)] = []
  for key in keys {
    guard (r.session)(key) is Some(row) else { continue }
    let ids = uniq([text_at(row, "profile"), ..strings_of(at(row, "profiles")), ..(r.ran_on)(key)])
    for id in ids {
      if !out.iter().any(x => x.0 == id) {
        out.push((id, self.w.part("accounts.of", [js(id)])))
      }
    }
  }
  out
}

///|
/// Of `accounts`, the logins sessions `keys` only ran on before or list, none of them runs on now, that cannot go.
pub async fn Handover::past_left(self : Handover, accounts : Array[(String, J)], keys : Array[String], reads? : SessionReads? = None) -> Array[String] {
  let r = reads.unwrap_or(self.reads())
  let now = []
  for k in keys {
    match (r.session)(k) {
      Some(row) =>
        match str_at(row, "profile") {
          Some(p) => now.push(p)
          None => ()
        }
      None => ()
    }
  }
  accounts.filter(a => a.1 is Null && !now.contains(a.0)).map(a => a.0)
}

///|
/// Hands chat `key` (and those sharing its home chat) to `to`: checked, held, sent, switched.
pub async fn Handover::hand_over(
  self : Handover,
  key : String,
  to : String,
  wait? : Bool = false,
  ignore_files? : Bool = false,
  progress? : ((J) -> Unit)? = None,
  stopped_for? : J? = None,
) -> J {
  self.loaded_within()
  match self.check(key, to, ignore_files~, stopped_for~) {
    Some(why) => raise refused(why)
    None => ()
  }
  let keys = self.together(key)
  let ws = str_of(Some(self.hub("wsOf", [js(key)]))).unwrap_or("")
  if !wait {
    for k in keys {
      if self.hub("busy", [js(k)]) is Bool(true) {
        raise refused(self.why("inTurn", args=[("chat", self.chat_name(k))]))
      }
    }
  }
  let name = match (self.d.roster)(ws) {
    Some(r) =>
      match r.search_by(s => s.id == to) {
        Some(i) => r[i].name
        None => ""
      }
    None => ""
  }
  let now = self.w.now()
  let o : Rec = {
    j: jo([
      ("id", js(handover_id(self.w.fs, keys, to, now))),
      ("keys", jstrs(keys)),
      ("to", js(to)),
      ("toName", js(name)),
      ("ws", js(ws)),
      ("at", jn(now)),
      ("step", js("files")),
      ("error", Null),
      ("jobs", ja([])),
      ("dropOwed", jb(false)),
      ("sent", jo([])),
      ("counts", Null),
      ("there", jo([])),
      ("routes", ja([])),
      ("routed", ji(0)),
      ("shown", jb(false)),
      ("done", ji(0)),
      ("total", ji(0)),
      ("held", jb(false)),
      ("v", ji(2)),
    ]),
  }
  self.keep_out(o)
  self.save(o)
  let who = if name != "" { name } else { head_of(to, 12) }
  let first = keys.get(0).unwrap_or("")
  let begun = try {
    self.given(o)
    self.mark(o, "begin")
    let begun = self.begin_there(o, stopped_for)
    o.set("usage", jb(at(begun, "usage") is Some(Bool(true))))
    self.mark(o, "first")
    self.files(o, begun, progress, false)
    self.mark(o, "turn")
    for k in keys {
      if !(self.hub("busy", [js(k)]) is Bool(true)) {
        continue
      }
      if !wait {
        raise said(self.why("inTurn", args=[("chat", self.chat_name(k))]))
      }
      let ended : Later[Bool] = Later::new()
      // timer: a deadline for the turn's end
      let late = self.w.after(turn_wait_ms, () => ended.resolve(false))
      self.waiting_turn[o.s("id")] = true
      self.w.go(async fn() {
        ignore(self.hub("turnEnded", [js(k)])) catch {
          _ => ()
        }
        ended.resolve(true)
      })
      let came = ended.wait()
      self.waiting_turn.remove(o.s("id"))
      late()
      if !came {
        raise said(self.why("turnLate", args=[("chat", self.chat_name(k)), ("minutes", num_text(turn_wait_ms / 60000.0))]))
      }
    }
    begun
  } catch {
    e => {
      let error = say_of(self.w, e, "chat \{first}")
      if self.closed {
        raise refused(self.w.tr("station.move.stoppedMidway", args=[("station", who)]))
      }
      self.fail(o, error)
      raise refused(self.w.tr("station.move.chatStayed", args=[("station", who), ("why", error)]))
    }
  }
  self.given(o) catch {
    e => {
      let error = say_of(self.w, e, "chat \{first}")
      self.fail(o, error)
      raise refused(self.w.tr("station.move.chatStayed", args=[("station", who), ("why", error)]))
    }
  }
  self.mark(o, "hold")
  for k in keys {
    ignore(self.hub("holdChat", [js(k), js("moving to \{if name != "" { name } else { head_of(to, 8) }}")]))
  }
  o.set("held", jb(true))
  o.set("step", js("held"))
  o.set("jobs", self.w.part("jobs.of", [jstrs(keys)]))
  self.save(o)
  self.failing("held")
  ignore(self.w.part("jobs.stop", [jstrs(keys), js("its chat is being handed to \{if name != "" { name } else { "another station" }}")]))
  self.send(o, progress, begun) catch {
    e => {
      let error = say_of(self.w, e, "chat \{first}")
      if self.closed {
        raise refused(self.w.tr("station.move.stoppedHeld", args=[("station", who)]))
      }
      self.fail(o, error)
      raise refused(self.w.tr("station.move.chatStayed", args=[("station", who), ("why", error)]))
    }
  }
  self.after_gone(o) catch {
    e => {
      self.w.warn("handover", "a chat that went is not all told there yet", jo([("id", js(o.s("id"))), ("error", js(message_of(e)))]))
      self.retry(o)
    }
  }
  o.j
}

///|
/// A test's failure made at `step`.
async fn Handover::failing(self : Handover, step : String) -> Unit {
  match self.d.fail {
    Some(f) => f(step)
    None => ()
  }
}

///|
/// Begun there: its accounts there, its connects as they are known there, said first.
async fn Handover::begin_there(self : Handover, o : Rec, stopped_for : J?) -> J {
  let here = (self.d.here)().unwrap_or("")
  let keys = o.keys()
  let accounts = self.accounts_of(keys)
  let used_all = []
  for k in keys {
    used_all.push(text_at(self.store("getSession", [js(k)]), "connect"))
    for t in items(Some(self.store("sessionThreads", [js(k)]))) {
      used_all.push(text_at(t, "connect"))
    }
  }
  let used = uniq(used_all.filter(c => c != ""))
  let connects = connects_there(used.filter(c => !is_internal(c)), used, here, o.s("to"))
  let described = []
  if self.d.connects {
    for id in used {
      match self.w.part("connects.describedFor", [js(id)]) {
        Null => ()
        it =>
          described.push(
            jo([("known", known_json(known_of(id, here))), ("station", at(it, "station").unwrap_or(Null)), ("described", at(it, "described").unwrap_or(Null))]),
          )
      }
    }
  }
  let left = self.past_left(self.accounts_of(keys), keys)
  let nowhere = []
  for a in accounts {
    let present = self.w.part("accounts.present", [js(a.0)])
    if present is Bool(false) || left.contains(a.0) {
      nowhere.push(a.0)
    }
  }
  self.w.ask(
    o.s("to"),
    jo([
      ("method", js("handover.begin")),
      ("keys", jstrs(keys)),
      ("ws", js(o.s("ws"))),
      ("dataDir", js(self.d.data)),
      ("accounts", jo(accounts)),
      ("nowhere", jstrs(nowhere)),
      ("connects", pairs_json(connects)),
      ("described", ja(described)),
      ("stoppedFor", stopped_for.unwrap_or(Null)),
      ("bindings", self.bindings_of(keys)),
      ("workspace", js(o.s("ws"))),
      ("origin", js(here)),
      ("id", js(o.s("id"))),
    ]),
  )
}

///|
async fn Handover::bindings_of(self : Handover, keys : Array[String]) -> J {
  match self.w.part("bindingsOf", [jstrs(keys)]) {
    Obj(_) as b => b
    _ => jo([])
  }
}

///|
/// What carrying a chat's files failed of, in the station's words.
fn Handover::carry_words(self : Handover, e : Error) -> Error {
  if kind_of(e) == "Gone" {
    return said(self.why("carryUnanswered"))
  }
  if is_refused(e) || is_said(e) {
    return e
  }
  let code = code_of(e)
  if code == "EACCES" || code == "EPERM" {
    let path = match e {
      Thrown(_, f) => text_at(f, "path")
      _ => ""
    }
    return said(self.why("cannotRead", args=[("path", path), ("count", "1")]))
  }
  if code == "ENOSPC" {
    return said(self.why("noSpace"))
  }
  let cause = message_of(e)
  self.w.warn("handover", "a chat's files could not be carried", jo([("error", js(cause)), ("code", if code == "" { Null } else { js(code) })]))
  said(self.why(if unanswered(cause) { "carryUnanswered" } else { "carryFailed" }))
}

///|
/// A request to the station hand-over `o` goes to, with its own fields after what it says.
async fn Handover::ask_to(self : Handover, o : Rec, fields : Array[(String, J)], body? : Body) -> J {
  let here = (self.d.here)().unwrap_or("")
  self.w.ask(o.s("to"), jo([..fields, ("workspace", js(o.s("ws"))), ("origin", js(here)), ("id", js(o.s("id")))]), body?)
}

///|
/// Its files: gathered alone, what is not in place there sent, placed and checked there.
async fn Handover::files(self : Handover, o : Rec, begun : J, progress : ((J) -> Unit)?, held : Bool) -> Unit {
  let fs = self.w.fs
  let d = self.d
  let here = (d.here)().unwrap_or("")
  o.set("step", js("files"))
  self.save(o)
  let db = fs.join([d.data, "stillfail.db"])
  let g = (d.work.gather)(d.data, db, o.s("ws"), false, scratch_of(fs, d.data, o.s("id")), None, Some(o.keys())) catch {
    e => raise self.carry_words(e)
  }
  if num_at(g, "unreadableCount").unwrap_or(0.0) > 0.0 {
    raise said(
      self.why("cannotRead", args=[("path", strings_of(at(g, "unreadable")).join("、")), ("count", num_text(num_at(g, "unreadableCount").unwrap_or(0.0)))]),
    )
  }
  let floor = floor_of(num_at(begun, "total"))
  let who = if o.s("toName") != "" { o.s("toName") } else { head_of(o.s("to"), 12) }
  let free = num_at(begun, "free")
  let fits = async fn(adds : Double) {
    let need = adds + (adds / 20.0).ceil()
    match free {
      Some(f) if f - need < floor =>
        raise said(self.why("noRoom", args=[("station", who), ("free", gb(f)), ("need", gb(need)), ("floor", gb(floor))]))
      _ => ()
    }
  }
  let gits = num_at(g, "gits").unwrap_or(0.0)
  if gits > 0.0 && at(begun, "git") is Some(Bool(false)) {
    raise said(self.why("noGit", args=[("station", who), ("n", num_text(gits))]))
  }
  self.failing("files")
  let bytes = num_at(g, "bytes").unwrap_or(0.0)
  let adds = match free {
    Some(f) if !held && f - (bytes + (bytes / 20.0).ceil()) < floor => Some(fits)
    _ => None
  }
  let carry = send_gathered(
    fs,
    g,
    {
      lacking: async fn(hashes, files) {
        let asked = files.map(f => {
          let fields = [("hash", js(f.hash)), ("path", js(f.path)), ("size", jn(f.size)), ("mtimeMs", f.mtime)]
          match f.room {
            Some(r) => fields.push(("room", js(r)))
            None => ()
          }
          jo(fields)
        })
        let answer = self.ask_to(o, [("method", js("handover.lacking")), ("hashes", jstrs(hashes)), ("files", ja(asked))])
        let lacking = match at(answer, "lacking") {
          Some(Arr(_) as l) => strings_of(Some(l))
          _ => hashes.copy()
        }
        let mut rest = unchecked_of(answer)
        while rest.length() > 0 {
          let again = self.ask_to(o, [
            ("method", js("handover.lacking")),
            ("hashes", jstrs(rest)),
            ("files", ja(asked.filter(f => rest.contains(text_at(f, "hash"))))),
          ])
          let said_lacking = match at(again, "lacking") {
            Some(Arr(_) as l) => strings_of(Some(l))
            _ => rest
          }
          for h in rest {
            if !said_lacking.contains(h) {
              match lacking.search_by(x => x == h) {
                Some(i) => ignore(lacking.remove(i))
                None => ()
              }
            }
          }
          let next = unchecked_of(again)
          if next.length() >= rest.length() {
            break
          }
          rest = next
        }
        let fields = [("lacking", jstrs(uniq(lacking)))]
        if text_at(answer, "pack") == pack_encoding {
          fields.push(("pack", js(pack_encoding)))
        }
        jo(fields)
      },
      put: async fn(hash, body, path, size) {
        let answer = self.w.ask(
          o.s("to"),
          jo([("method", js("handover.put")), ("workspace", js(o.s("ws"))), ("origin", js(here)), ("id", js(o.s("id"))), ("name", js(hash))]),
          body~,
        )
        if carried_place(fs, d.data, path) {
          o.set("sentBytes", jn(o.n("sentBytes") + size))
        }
        answer
      },
      put_pack: Some(async fn(entries, body, strict) {
        let fields = [
          ("method", js("handover.put")),
          ("workspace", js(o.s("ws"))),
          ("origin", js(here)),
          ("id", js(o.s("id"))),
          ("pack", js(pack_encoding)),
          ("strict", jb(strict)),
          ("count", ji(entries.length())),
        ]
        if entries.length() == 1 {
          fields.push(("name", js(entries[0].hash)))
        }
        self.w.ask(o.s("to"), jo(fields), body~)
      }),
      took: Some(f => if carried_place(fs, d.data, f.path) { o.set("sentBytes", jn(o.n("sentBytes") + f.size)) }),
      pack_files: d.pack_files,
      pack_bytes: d.pack_bytes,
      most: d.lack_most,
      stopping: () => self.closed || o.b("abandoned"),
      total: b => if !held {
        o.set("total", jn(b))
        o.set("done", ji(0))
        match progress {
          Some(p) => p(jo([("done", ji(0)), ("total", jn(b)), ("unit", js("bytes"))]))
          None => ()
        }
      },
      done: b => if !held {
        o.set("done", jn(o.n("done") + b))
        match progress {
          Some(p) => p(jo([("done", jn(o.n("done"))), ("total", jn(o.n("total"))), ("unit", js("bytes"))]))
          None => ()
        }
      },
      adds,
    },
    held,
    indexed=true,
  ) catch {
    e => raise self.carry_words(e)
  }
  self.given(o)
  guard carry is Some(carry) else { raise said(self.why("stopping")) }
  let key = "place:\{o.s("id")}:\{if held { "held" } else { "first" }}:\{carry}"
  let placed = self.wait_step(
    o,
    key,
    () => jo([
      ("method", js("handover.place")),
      ("workspace", js(o.s("ws"))),
      ("origin", js(here)),
      ("id", js(o.s("id"))),
      ("carry", js(carry)),
      ("held", jb(held)),
      ("told", js(key)),
    ]),
    progress=Some(p => match (num_at(p, "done"), num_at(p, "total")) {
      (Some(done), Some(total)) => {
        o.set("placing", jo([("done", jn(done)), ("total", jn(total))]))
        self.w.part_tell("changed", [js(o.s("id"))])
      }
      _ => ()
    }),
  ) catch {
    e => {
      o.del("placing")
      raise e
    }
  }
  o.del("placing")
  match num_at(placed, "missing") {
    Some(m) if held && m > 0.0 => raise said(self.why("filesMissing", args=[("n", num_text(m))]))
    _ => ()
  }
}

///|
/// Held, steps 3 to 5 up to `gone`: its files again, its rows, the counts.
async fn Handover::send(self : Handover, o : Rec, progress : ((J) -> Unit)?, begun : J) -> Unit {
  let fs = self.w.fs
  let d = self.d
  let here = (d.here)().unwrap_or("")
  self.mark(o, "held")
  self.files(o, begun, progress, true)
  self.given(o)
  self.mark(o, "rows")
  o.set("step", js("rows"))
  self.save(o)
  self.failing("rows")
  let sent = self.send_rows(o, None)
  let pruning = "prune:\{o.s("id")}"
  ignore(
    self.wait_step(o, pruning, () => jo([
      ("method", js("handover.prune")),
      ("workspace", js(o.s("ws"))),
      ("origin", js(here)),
      ("id", js(o.s("id"))),
      ("told", js(pruning)),
    ])),
  )
  self.mark(o, "counts")
  let counts = at(self.ask_to(o, [("method", js("handover.counts"))]), "counts")
  self.failing("counts")
  self.given(o)
  let differs = match counts {
    None => Some("it said nothing")
    Some(c) => self.differ(sent, c)
  }
  match differs {
    Some(what) => raise said(self.why("notWhatSent", args=[("what", what)]))
    None => ()
  }
  let counts = counts.unwrap()
  o.set("counts", counts)
  let there = []
  for k in o.keys() {
    let thread = at(self.store("homeChat", [js(k)]), "id").unwrap_or(Null)
    let there_id = match at(at(counts, "homes").unwrap_or(Null), k) {
      Some(Num(n)) => jn(n)
      _ => Null
    }
    there.push((k, jo([("thread", thread), ("there", there_id)])))
  }
  o.set("there", jo(there))
  let routes = []
  for k in o.keys() {
    for t in items(Some(self.store("sessionThreads", [js(k)]))) {
      let thread = at(t, "thread").unwrap_or(Null)
      let connect = text_at(t, "connect")
      if text_at(thread, "surface") == stillfail_surface || is_internal(connect) {
        continue
      }
      if self.d.connects {
        match self.w.part("connects.kindOf", [js(connect)]) {
          Null => ()
          kind => if !routed(kind) { continue }
        }
      }
      routes.push(jo([("connect", js(connect)), ("channel", at(thread, "channel").unwrap_or(Null)), ("threadTs", at(thread, "threadTs").unwrap_or(Null))]))
    }
  }
  o.set("routes", ja(routes))
  self.save(o)
  self.failing("decide")
  if decided(fs, d.data, o.s("id"), "gone") != "gone" {
    let who = if o.s("toName") != "" { o.s("toName") } else { head_of(o.s("to"), 12) }
    raise said(self.w.tr("station.move.restartedMidway", args=[("station", who)]))
  }
  self.mark(o, "gone")
  o.set("step", js("gone"))
  self.save(o)
  self.failing("gone")
  ignore(self.store("goneTo", [jstrs(o.keys()), js(o.s("to")), o.get("there").unwrap_or(jo([]))]))
  if !o.b("usage") {
    self.usage_again_for(o.s("to")) catch {
      e =>
        self.w.warn("handover", "the calls of chats handed before not looked at again", jo([("to", js(head_of(o.s("to"), 12))), ("error", js(message_of(e)))]))
    }
  }
  ignore(self.w.part("went", [jstrs(o.keys())]))
  fs.rm_rf(scratch_of(fs, d.data, o.s("id")))
  let (ms, total) = took_of(o.get("began"), self.w.now())
  self.w.info(
    "handover",
    "a chat went to another station",
    jo([("id", js(o.s("id"))), ("to", js(o.s("to"))), ("keys", ji(o.keys().length())), ("ms", ms), ("total", jn(total))]),
  )
}

///|
/// What was sent, counted as the station it goes to counts it.
priv struct Counted {
  mut sessions : Double
  entries : Array[(String, Double)]
  letters : Array[(String, Double)]
  rows : Array[(String, Double)]
}

///|
fn bump(xs : Array[(String, Double)], k : String, n : Double) -> Unit {
  match xs.search_by(x => x.0 == k) {
    Some(i) => xs[i] = (k, xs[i].1 + n)
    None => xs.push((k, n))
  }
}

///|
/// The chat's rows sent a page at a time (`from`: each thread's entries and letters after what was sent, alone).
async fn Handover::send_rows(self : Handover, o : Rec, from : J?) -> Counted {
  let sent : Counted = { sessions: 0.0, entries: [], letters: [], rows: [] }
  let keys = jstrs(o.keys())
  let page = async fn(table : String, rows : Array[J]) {
    if rows.length() == 0 {
      return
    }
    ignore(self.ask_to(o, [("method", js("handover.rows")), ("table", js(table)), ("rows", ja(rows)), ("page", js(self.w.fs.random_hex(8)))]))
    if table == "sessions" {
      sent.sessions += rows.length().to_double()
    } else if table == "entries" || table == "letters" {
      for r in rows {
        let t = match at(r, "thread") {
          Some(Num(n)) => num_text(n)
          Some(v) => show_value(Some(v))
          None => "undefined"
        }
        bump(if table == "entries" { sent.entries } else { sent.letters }, t, 1.0)
      }
    } else if table != "threads" {
      bump(sent.rows, table, rows.length().to_double())
    }
  }
  let pages = async fn(table : String, of : J, after0 : J) -> J? {
    let mut after = after0
    let mut last : J? = None
    while true {
      let rows = items(Some(self.store("chatPage", [js(table), of, after, ji(500), keys])))
      page(table, rows)
      match rows.last() {
        Some(r) => last = Some(r)
        None => ()
      }
      if rows.length() < 500 ||
        table == "threads" ||
        table == "sessions" ||
        table == "thread_sessions" ||
        table == "opened_chats" ||
        table == "session_usage" {
        return last
      }
      after = after_of(table, rows[rows.length() - 1])
    }
    last
  }
  if from is None {
    for k in o.keys() {
      ignore(pages("sessions", js(k), Null))
    }
  }
  let mut after = 0.0
  while true {
    let threads = items(Some(self.store("chatThreads", [keys, jn(after), ji(200)])))
    for t in threads {
      let tid = match t {
        Num(n) => num_text(n)
        v => show_value(Some(v))
      }
      if from is None {
        ignore(pages("threads", t, Null))
        ignore(pages("thread_sessions", t, Null))
      }
      let was = match from {
        Some(f) => at(f, tid)
        None => None
      }
      let was_e = match was {
        Some(w) => num_at(w, "entries").unwrap_or(0.0)
        None => 0.0
      }
      let was_l = match was {
        Some(w) => num_at(w, "letters").unwrap_or(0.0)
        None => 0.0
      }
      let last_e = pages("entries", t, if from is None { Null } else { jn(was_e) })
      let last_l = pages("letters", t, if from is None { Null } else { jn(was_l) })
      let n_of = (r : J?) => match r {
        Some(row) => num_at(row, "n").unwrap_or(0.0)
        None => 0.0
      }
      let e = if was_e > n_of(last_e) { was_e } else { n_of(last_e) }
      let l = if was_l > n_of(last_l) { was_l } else { n_of(last_l) }
      let sent_now = match o.get("sent") {
        Some(Obj(_) as s) => s
        _ => jo([])
      }
      o.set("sent", set(sent_now, tid, jo([("entries", jn(e)), ("letters", jn(l))])))
      if from is None {
        for table in ["closed_cards", ..marks_tables] {
          ignore(pages(table, t, Null))
        }
      }
    }
    if threads.length() < 200 {
      break
    }
    after = num_of(threads.last()).unwrap_or(after)
  }
  for k in o.keys() {
    let tables = if from is None { ["turns", "runtime_sessions", "pins", "opened_chats", "deliveries"] } else { ["deliveries"] }
    for table in tables {
      ignore(pages(table, js(k), Null))
    }
  }
  if o.b("usage") {
    let was = o.get("usageSent").unwrap_or(jo([]))
    let last = []
    for k in o.keys() {
      let after = match from {
        None => J::Null
        Some(_) => at(was, k).unwrap_or(Null)
      }
      let end = pages("usage", js(k), after)
      last.push((
        k,
        match end {
          None => after
          Some(r) => ja([jn(num_at(r, "at").unwrap_or(0.0)), js(show_value(at(r, "id")))])
        },
      ))
      ignore(pages("usage_files", js(k), Null))
      ignore(pages("session_usage", js(k), Null))
    }
    o.set("usageSent", jo(last))
  }
  sent
}

///|
/// Where what was sent and what it has differ, in words (None: they do not).
fn Handover::differ(self : Handover, sent : Counted, there : J) -> String? {
  let there_n = num_at(there, "sessions").unwrap_or(0.0)
  if sent.sessions != there_n {
    return Some(self.why("countSessions", args=[("sent", num_text(sent.sessions)), ("there", show_value(at(there, "sessions")))]))
  }
  for kind in ["entries", "letters"] {
    for e in if kind == "entries" { sent.entries } else { sent.letters } {
      let t = num_at(at(there, kind).unwrap_or(Null), e.0).unwrap_or(0.0)
      if t != e.1 {
        return Some(self.why("countThread", args=[("sent", num_text(e.1)), ("what", kind), ("there", num_text(t))]))
      }
    }
  }
  for e in sent.rows {
    let t = num_at(at(there, "rows").unwrap_or(Null), e.0).unwrap_or(0.0)
    if t != e.1 {
      return Some(self.why("countRows", args=[("sent", num_text(e.1)), ("table", e.0), ("there", num_text(t))]))
    }
  }
  None
}

///|
/// After it went: what was said meanwhile, then B told to show it, then each of its platform threads re-pointed.
async fn Handover::after_gone(self : Handover, o : Rec) -> Unit {
  if o.s("step") == "done" || o.b("ended") {
    return
  }
  let here = (self.d.here)().unwrap_or("")
  let keys = o.keys()
  if !o.b("shown") {
    self.mark(o, "show")
    for r in items(o.get("routes")) {
      let connect = text_at(r, "connect")
      if self.d.connects && str_at(self.w.part("connects.describedFor", [js(connect)]), "station") == Some(here) {
        ignore(self.w.part("connects.route", [js(connect), at(r, "channel").unwrap_or(Null), at(r, "threadTs").unwrap_or(Null), js(o.s("to"))]))
      }
      ignore(self.hub("drained", [js(connect), at(r, "channel").unwrap_or(Null), at(r, "threadTs").unwrap_or(Null)]))
    }
    ignore(self.send_rows(o, Some(o.get("sent").unwrap_or(jo([])))))
    self.failing("show")
    let threads = []
    for t in entries(o.get("there")) {
      match (at(t.1, "thread"), at(t.1, "there")) {
        (Some(Num(a)), Some(Num(b))) => threads.push(ja([jn(a), jn(b)]))
        _ => ()
      }
    }
    let sends = match self.w.part("keptSends", [ja(threads)]) {
      Arr(_) as s => s
      _ => ja([])
    }
    ignore(self.ask_to(o, [("method", js("handover.show")), ("sends", sends)]))
    o.set("shown", jb(true))
    self.save(o)
  }
  ignore(self.store("shownThere", [jstrs(keys), jopt((self.d.home)())]))
  for k in keys {
    ignore(self.hub("releaseChat", [js(k)]))
  }
  if !o.b("caught") {
    let mut since = false
    for t in entries(o.get("sent")) {
      let tid = parse(t.0) catch { _ => J::Null }
      let e = items(Some(self.store("chatPage", [js("entries"), tid, at(t.1, "entries").unwrap_or(Null), ji(1), jstrs(keys)])))
      let l = if e.length() > 0 {
        []
      } else {
        items(Some(self.store("chatPage", [js("letters"), tid, at(t.1, "letters").unwrap_or(Null), ji(1), jstrs(keys)])))
      }
      if e.length() > 0 || l.length() > 0 {
        since = true
        break
      }
    }
    if !since {
      for k in keys {
        if items(Some(self.store("chatPage", [js("deliveries"), js(k), Null, ji(1), jstrs(keys)]))).length() > 0 {
          since = true
          break
        }
      }
    }
    if !since && o.b("usage") {
      for k in keys {
        let after = at(o.get("usageSent").unwrap_or(jo([])), k).unwrap_or(Null)
        if items(Some(self.store("chatPage", [js("usage"), js(k), after, ji(1)]))).length() > 0 {
          since = true
          break
        }
      }
    }
    if since {
      ignore(self.send_rows(o, Some(o.get("sent").unwrap_or(jo([])))))
      ignore(self.ask_to(o, [("method", js("handover.show")), ("sends", ja([]))]))
    }
    ignore(self.store("deliveredThere", [jstrs(keys)]))
    o.set("caught", jb(true))
    self.save(o)
  }
  while o.n("routed") < items(o.get("routes")).length().to_double() {
    let r = items(o.get("routes"))[o.n("routed").to_int()]
    if self.d.connects {
      ignore(self.w.part("connects.route", [at(r, "connect").unwrap_or(Null), at(r, "channel").unwrap_or(Null), at(r, "threadTs").unwrap_or(Null), js(o.s("to"))]))
    }
    self.save(o)
    o.set("routed", jn(o.n("routed") + 1.0))
  }
  self.mark(o, "done")
  o.set("step", js("done"))
  self.save(o)
}

///|
/// It did not go: B told to take out what it put in, the chat back to work here, its jobs started again.
async fn Handover::fail(self : Handover, o : Rec, error : String) -> Unit {
  let fs = self.w.fs
  if decided(fs, self.d.data, o.s("id"), "failed") == "gone" {
    self.w.warn("handover", "a hand-over that went is not failed", jo([("id", js(o.s("id"))), ("to", js(o.s("to"))), ("error", js(error))]))
    return
  }
  self.w.warn("handover", "a chat was not handed over: it goes on here", jo([("id", js(o.s("id"))), ("to", js(o.s("to"))), ("error", js(error))]))
  o.set("step", js("failed"))
  o.set("error", js(error))
  o.set("dropOwed", jb(true))
  self.save(o)
  if !(o.get("held") is Some(Bool(false))) {
    for k in o.keys() {
      if !(self.hub("releaseChat", [js(k)]) is Bool(true)) {
        ignore(self.hub("wakeChat", [js(k)]))
      }
    }
  }
  for j in items(o.get("jobs")) {
    ignore(self.w.part("jobs.start", [j])) catch {
      e => self.w.warn("handover", "a job of a chat not handed over not started again", jo([("job", at(j, "name").unwrap_or(Null)), ("error", js(message_of(e)))]))
    }
  }
  fs.rm_rf(scratch_of(fs, self.d.data, o.s("id")))
  self.drop_out(o) catch {
    _ => self.retry(o)
  }
}

///|
async fn Handover::drop_out(self : Handover, o : Rec) -> Unit {
  ignore(self.ask_to(o, [("method", js("handover.drop"))]))
  o.set("dropOwed", jb(false))
  self.save(o)
}

///|
/// What is owed to B told (after it went: the rest; failed: the drop), again until it answers.
fn Handover::go(self : Handover, o : Rec) -> Unit {
  let id = o.s("id")
  if self.closed || self.runs.contains(id) || o.b("ended") {
    return
  }
  match self.again.get(id) {
    Some(f) => f()
    None => ()
  }
  self.again.remove(id)
  let run = self.w.run(async fn() {
    try {
      if o.s("step") == "gone" {
        self.after_gone(o)
      } else if o.b("dropOwed") {
        self.drop_out(o)
      }
      self.tries.remove(id)
    } catch {
      _ => self.retry(o)
    }
    self.runs.remove(id)
  })
  if !run.is_done() {
    self.runs[id] = run
  }
}

///|
fn Handover::retry(self : Handover, o : Rec) -> Unit {
  if self.closed || o.b("ended") {
    return
  }
  let id = o.s("id")
  let n = self.tries.get(id).unwrap_or(0)
  self.tries[id] = n + 1
  // timer: a retry after a failure
  self.again[id] = self.w.after(backoff(retire_retry_ms, n, retire_retry_most_ms), () => self.go(o))
}

///|
/// The other station came up (its link opened): what is owed to it told now.
pub fn Handover::reached(self : Handover, station : String) -> Unit {
  if !self.ready {
    return
  }
  self.w.go(async fn() { self.mend(Some(station)) })
  self.sync_handed_usage(Some(station))
  for id in self.unsure.copy() {
    match self.ins.get(id) {
      Some(i) if i.s("step") == "coming" => if i.s("origin") == station { self.ask_still(i) }
      _ => remove_str(self.unsure, id)
    }
  }
  self.look("reached", self.owed_outs.length())
  for o in self.owed_outs.copy() {
    if o.s("step") != "gone" && !o.b("dropOwed") {
      continue
    }
    if o.s("step") == "gone" && o.b("shown") {
      let routes = items(o.get("routes"))
      let from = o.n("routed").to_int()
      let rest = if from < routes.length() { routes[from:].to_array() } else { [] }
      let o2 = o
      self.w.go(async fn() {
        let mut owed = false
        if self.d.connects {
          for r in rest {
            if str_of(Some(self.w.part("connects.runsOn", [at(r, "connect").unwrap_or(Null)]))) == Some(station) {
              owed = true
              break
            }
          }
        }
        if owed {
          self.go(o2)
        }
      })
    } else if o.s("to") == station {
      self.go(o)
    }
  }
}

///|
fn remove_str(xs : Array[String], s : String) -> Unit {
  match xs.search_by(x => x == s) {
    Some(i) => ignore(xs.remove(i))
    None => ()
  }
}

///|
async fn Handover::save(self : Handover, o : Rec) -> Unit {
  self.owed_now(o)
  self.w.fs.write_json(out_file(self.w.fs, self.d.data, o.s("id")), o.j)
  self.w.part_tell("changed", [js(o.s("id"))])
}

///|
async fn Handover::save_in(self : Handover, i : Rec) -> Unit {
  self.coming_now(i)
  self.w.fs.write_json(in_file(self.w.fs, self.d.data, i.s("id")), i.j)
  self.w.part_tell("changed", [js(i.s("id"))])
}
