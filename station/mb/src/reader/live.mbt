// The live view of the sessions (station/src/sessions/live.ts `LiveHub`, the pseudo-actor `#live` of the sessions'
// program): what a running turn is doing, told at its turning points (the phase, each step starting and ending), how
// fast the model writes, what a session has going in the background and its checklist, and its transcripts' entries
// as each is written whole, to whoever follows the session (a device's stream, or the station itself while the session
// is at work: `running`). Nothing here is stored. A Claude session's events come from its process read in this program
// (actors.mbt `routed`), any other runtime's from Node; a turn's end waits for what its transcript said last
// (`live_turn_end`). What is read of a transcript (where it is, what it gained, its past a page at a time) is the
// readers' (other processes, so no read of a long transcript holds up the actors here), asked through Node (`lnode`),
// which also watches the files written to (`arm`) and says when one changed (`soon`), and gives what is told to its
// listeners (`told`).

///|
priv struct LBucket {
  at : Double
  step : String
  mut tokens : Double
  since : Double?
}

///|
/// What the model wrote in each quarter second of the window, by the step it wrote it in (live.ts `Rate`).
priv struct LRate {
  mut buckets : Array[LBucket]
  mut told_at : Double
  mut told : Int
  last : Map[String, Double]
}

///|
priv struct PItem {
  mut text : String
  mut status : String
  mut id : String?
}

///|
/// Where reading a transcript's checklist stands (read/plan.ts `PlanState`).
priv struct LPlan {
  mut items : Array[PItem]
  creating : Map[String, PItem]
}

///|
/// One transcript of a session's chain, as far as it was read (`state`, a tail.ts `TailState`; none: not yet).
priv struct LOne {
  runtime : String
  path : String
  mut state : Json?
}

///|
/// A session's transcripts read as they grow (read/read-tail.ts `ReadTail`, keeping none of what it read).
priv struct LTail {
  runtime : String
  mut tails : Array[LOne]
}

///|
/// A listener: told the entries in brief or whole, what is said while it joins held (`queue`) until it has.
/// `held`: the station's own (`running`), whose messages go to every stream following the sessions at work.
priv struct LSub {
  id : Int
  brief : Bool
  held : Bool
  mut queue : Array[Json]?
}

///|
/// A session watched (live.ts `Watched`): `n` tells one from a later one of the same key.
priv struct LWatched {
  n : Int
  mut tail : LTail?
  /// where it stands still being found: what waits for it (a listener joining, a read) runs once it is (`ready_now`)
  mut ready : Bool
  waiters : Array[() -> Unit]
  mut reading : Bool
  mut behind : Bool
  mut announce : Bool
  /// one read of it at a time (`in_read`): whether one runs, and those waiting their turn
  mut read_held : Bool
  read_queue : Array[@effect.Deferred[Unit]]
  mut locating : Bool
  mut following : Int
  mut follow_again : Bool
  mut carried : Array[Json]?
  mut take_up : ((Array[Json]) -> Bool)?
  mut armed : String?
}

///|
priv struct LiveState {
  steps : Map[String, Array[Json]]
  phase : Map[String, (String, Double)]
  rates : Map[String, LRate]
  tasks : Map[String, Array[Json]]
  plans : Map[String, LPlan]
  plan_at : Map[String, Int]
  plan_back : Map[String, Array[Json]]
  said_plans : Map[String, Json]
  listeners : Map[String, Array[LSub]]
  watched : Map[String, LWatched]
  stood : Map[String, Array[Json]]
  mut took_tails : Bool
  mut next : Int
  holds : Map[String, Int]
  releases : Map[String, () -> Unit]
  length_told : Map[String, Int]
  /// what a turn's end waits on, by the number it is known by (actors.mbt `routed`, `on_event`)
  ends : Map[Int, @effect.Deferred[Unit]]
  /// its fibers going (`lspawn`)
  mut pending : Int
}

///|
fn LiveState::new() -> LiveState {
  {
    steps: Map([]),
    phase: Map([]),
    rates: Map([]),
    tasks: Map([]),
    plans: Map([]),
    plan_at: Map([]),
    plan_back: Map([]),
    said_plans: Map([]),
    listeners: Map([]),
    watched: Map([]),
    stood: Map([]),
    took_tails: false,
    next: 0,
    holds: Map([]),
    releases: Map([]),
    length_told: Map([]),
    ends: Map([]),
    pending: 0,
  }
}

///|
let live_key : String = "#live"

///|
/// How much of a tool's input a step carries: enough to say what it runs.
let input_chars : Int = 300

///|
/// The fields of a call's input that say what it runs (live.ts `SAYING`).
let saying : Array[String] = [
  "description", "toolSummary", "command", "cmd", "CommandLine", "file_path", "path", "Path", "target_file", "target_directory",
  "DirectoryPath", "Directory", "SearchDirectory", "SearchPath", "pattern", "Pattern", "url", "query", "Query", "prompt", "Prompt",
  "station", "action", "name", "key", "id", "to", "chat", "title", "file", "method", "Role", "Recipient", "Message",
]

///|
let rate_every_ms : Double = 1000.0

///|
let rate_window_ms : Double = 2000.0

///|
let rate_first_ms : Double = 500.0

///|
/// How long a session is still followed once its turn is over (`running`).
let held_after_ms : Double = 120000.0

///|
/// Later than any time (what no bucket is before).
let never : Double = 1.0e300

///|
let plan_pages : Int = 4

///|
let plan_page : Int = 1000

///|
/// The first `n` characters of `text` (code points, as live.ts `takeChars`).
fn take_chars(text : String, n : Int) -> String {
  let b = StringBuilder::new()
  let mut i = 0
  for c in text {
    if i >= n {
      break
    }
    b.write_char(c)
    i += 1
  }
  b.to_string()
}

///|
/// A call's input as a step carries it (live.ts `briefInput`).
fn brief_input(input : String) -> String {
  let args = @json.parse(input) catch { _ => return take_chars(input, input_chars) }
  guard args is Object(fields) else { return take_chars(input, input_chars) }
  let kept : Map[String, Json] = {}
  for name in saying {
    match fields.get(name) {
      Some(String(v)) => kept[name] = Json::string(take_chars(v, input_chars))
      Some(Array(vs)) =>
        kept[name] = Json::array(
          vs.filter_map(p => match p {
            String(s) => Some(Json::string(take_chars(s, input_chars)))
            _ => None
          }),
        )
      _ => ()
    }
  }
  Json::object(kept).stringify()
}

///|
/// About how many tokens a piece of output is (live.ts `tokensOf`).
fn tokens_of(text : String) -> Double {
  let mut ascii = 0.0
  let mut other = 0.0
  for c in text {
    if c.to_int() < 0x80 {
      ascii += 1.0
    } else {
      other += 1.0
    }
  }
  ascii / 4.0 + other / 1.5
}

///|
fn base64_bytes(s : String) -> Int {
  if s.length() == 0 {
    return 0
  }
  let pad = if s.has_suffix("==") { 2 } else if s.has_suffix("=") { 1 } else { 0 }
  s.length() * 3 / 4 - pad
}

// ── a session's transcripts read as they grow ─────────────────────────────────────────────────────────────────────

///|
/// A transcript ref (tail.ts `TranscriptRef`) as a path and its runtime.
fn ref_of(runtime : String, r : Json) -> (String, String) {
  match r {
    String(p) => (p, runtime)
    _ => (str_of(r.value("path")).unwrap_or(""), str_of(r.value("runtime")).unwrap_or(runtime))
  }
}

///|
fn LTail::new(runtime : String, paths : Array[Json]) -> LTail {
  { runtime, tails: paths.map(r => { let (path, rt) = ref_of(runtime, r); { runtime: rt, path, state: None } }) }
}

///|
/// One that goes on from where another's reading stood (`ReadTail.from`).
fn LTail::from(runtime : String, states : Array[Json]) -> LTail {
  {
    runtime,
    tails: states.map(st => { runtime: str_of(st.value("runtime")).unwrap_or(runtime), path: str_of(st.value("path")).unwrap_or(""), state: Some(st) }),
  }
}

///|
fn LTail::snapshot(self : LTail) -> Array[Json] {
  self.tails.map(t => match t.state {
    Some(s) => s
    None =>
      {
        "path": jstr(t.path),
        "runtime": jstr(t.runtime),
        "offset": jnum(0.0),
        "partial": jstr(""),
        "count": jnum(0.0),
        "inner": Json::array([]),
        "packedStamp": Json::null(),
      }
  })
}

///|
fn LOne::length(self : LOne) -> Int {
  match self.state {
    Some(s) => int_of(s.value("count"))
    None => 0
  }
}

///|
fn LTail::length(self : LTail) -> Int {
  let mut n = 0
  for t in self.tails {
    n += t.length()
  }
  n
}

///|
fn LTail::read_bytes(self : LTail) -> Int {
  let mut n = 0
  for t in self.tails {
    if t.state is Some(s) {
      n += int_of(s.value("offset")) - base64_bytes(str_of(s.value("partial")).unwrap_or(""))
    }
  }
  n
}

///|
fn LTail::path(self : LTail) -> String {
  match self.tails.last() {
    Some(t) => t.path
    None => ""
  }
}

///|
/// Goes on into `paths` (`ReadTail.extend`): whether that changed anything.
fn LTail::go_on(self : LTail, paths : Array[Json]) -> Bool {
  let refs = paths.map(r => ref_of(self.runtime, r))
  let mut differ = refs.length() < self.tails.length()
  if !differ {
    for i, t in self.tails {
      if t.path != refs[i].0 || t.runtime != refs[i].1 {
        differ = true
        break
      }
    }
  }
  if differ {
    self.tails = refs.map(r => { runtime: r.1, path: r.0, state: None })
    return true
  }
  if refs.length() == self.tails.length() {
    return false
  }
  for i = self.tails.length(); i < refs.length(); i = i + 1 {
    self.tails.push({ runtime: refs[i].1, path: refs[i].0, state: None })
  }
  true
}

///|
/// Whether `states` are where `at`'s transcripts are read (live.ts `same`).
fn same_states(states : Array[Json]?, at : Json) -> Bool {
  guard states is Some(states) else { return false }
  let runtime = str_of(at.value("runtime")).unwrap_or("claude")
  let paths = match at.value("paths") {
    Some(Array(p)) => p
    _ => []
  }
  if states.length() != paths.length() {
    return false
  }
  for i, st in states {
    let (path, rt) = ref_of(runtime, paths[i])
    if str_of(st.value("path")) != Some(path) || str_of(st.value("runtime")).unwrap_or(runtime) != rt {
      return false
    }
  }
  true
}

///|
/// What the transcripts gained since they were last read (`ReadTail.readSoon`): where the entries begin, and them.
async fn Actors::read_soon(self : Actors, tail : LTail) -> (Int, Array[Json]) raise {
  let mut offset = 0
  let mut from : Int? = None
  let told : Array[Json] = []
  for t in tail.tails {
    // (after one that changed: read again from its start, numbered on from there)
    if from is Some(_) && t.length() > 0 {
      t.state = None
    }
    let had = t.length()
    let state = match t.state {
      Some(s) => s
      None => ({ "path": jstr(t.path), "runtime": jstr(t.runtime) } : Json)
    }
    let read = self.lnode("tailRead", [jstr(t.runtime), state])
    t.state = read.value("state")
    let entries = match read.value("entries") {
      Some(Array(e)) => e
      _ => []
    }
    let start = int_of(read.value("start"))
    if from is None && (entries.length() > 0 || start < had) {
      from = Some(offset + start)
    }
    if from is Some(_) {
      told.append(entries)
    }
    offset += t.length()
  }
  match from {
    Some(f) => (f, told)
    None => (offset, [])
  }
}

// ── the checklist ─────────────────────────────────────────────────────────────────────────────────────────────────

///|
fn plan_whole(tool : String) -> Bool {
  tool == "TodoWrite" || tool == "update_plan"
}

///|
fn plan_items(p : LPlan) -> Json {
  Json::array(p.items.map(i => ({ "text": jstr(i.text), "status": jstr(i.status) } : Json)))
}

///|
/// Reads `entries` into `p` (read/plan.ts `readPlan`): whether its items changed.
fn read_plan(p : LPlan, entries : Array[Json]) -> Bool {
  let mut changed = false
  for e in entries {
    if e.value("subagent") is Some(True) {
      continue
    }
    let kind = str_of(e.value("kind")).unwrap_or("")
    if kind == "tool_result" {
      guard str_of(e.value("callId")) is Some(call) else { continue }
      guard p.creating.get(call) is Some(made) else { continue }
      p.creating.remove(call)
      let text = str_of(e.value("text")).unwrap_or("")
      match created_id(text) {
        Some(id) => made.id = Some(id)
        None =>
          if e.value("ok") is Some(False) {
            p.items = p.items.filter(i => !physical_equal(i, made))
            changed = true
          }
      }
      continue
    }
    guard kind == "tool_call" else { continue }
    guard str_of(e.value("tool")) is Some(tool) else { continue }
    guard plan_whole(tool) || tool == "TaskCreate" || tool == "TaskUpdate" else { continue }
    let args = @json.parse(str_of(e.value("text")).unwrap_or("")) catch { _ => continue }
    guard args is Object(_) else { continue }
    if plan_whole(tool) {
      let list = match (args.value("todos"), args.value("plan")) {
        (Some(Array(l)), _) => l
        (_, Some(Array(l))) => l
        _ => continue
      }
      p.items = list.filter_map(t => {
        guard t is Object(_) else { return None }
        let text = match (str_of(t.value("content")), str_of(t.value("step"))) {
          (Some(c), _) => c
          (None, Some(st)) => st
          _ => ""
        }
        if text == "" {
          return None
        }
        Some({ text, status: str_of(t.value("status")).unwrap_or("pending"), id: None })
      })
      p.creating.clear()
      changed = true
    } else if tool == "TaskCreate" {
      let subject = str_of(args.value("subject")).unwrap_or("")
      if subject == "" {
        continue
      }
      let item = { text: subject, status: "pending", id: None }
      p.items = [..p.items, item]
      if str_of(e.value("callId")) is Some(call) {
        p.creating[call] = item
      }
      changed = true
    } else {
      let id = match args.value("taskId") {
        Some(String(s)) => Some(s)
        Some(Number(n, ..)) => Some(js_number(n))
        _ => None
      }
      let at = match id {
        Some(id) => p.items.search_by(i => i.id == Some(id))
        None => None
      }
      guard at is Some(at) else { continue }
      let status = str_of(args.value("status"))
      if status == Some("deleted") {
        p.items = p.items.filter(i => !physical_equal(i, p.items[at]))
      } else {
        let was = p.items[at]
        let item = { text: was.text, status: was.status, id: was.id }
        if status is Some(s) {
          item.status = s
        }
        match str_of(args.value("subject")) {
          Some(s) if s != "" => item.text = s
          _ => ()
        }
        p.items = p.items.mapi((i, x) => if i == at { item } else { x })
      }
      changed = true
    }
  }
  changed
}

///|
/// A number as JavaScript's String() writes it (a task's id given as a number).
fn js_number(n : Double) -> String {
  if n == n.floor() && n.abs() < 1.0e15 {
    n.to_int64().to_string()
  } else {
    n.to_string()
  }
}

///|
/// The id in a task tool's result (`Task #3 created …`).
fn created_id(text : String) -> String? {
  guard text.has_prefix("Task #") else { return None }
  let rest = text.view(start_offset=6)
  let b = StringBuilder::new()
  let mut n = 0
  for c in rest {
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      break
    }
    b.write_char(c)
    n += 1
  }
  if n == 0 {
    return None
  }
  let id = b.to_string()
  let after = rest.view(start_offset=id.length())
  if after.has_prefix(" created") {
    Some(id)
  } else {
    None
  }
}

///|
/// Whether an entry says the list whole (read/plan.ts `saysWhole`).
fn says_whole(e : Json) -> Bool {
  str_of(e.value("kind")) == Some("tool_call") &&
  !(e.value("subagent") is Some(True)) &&
  (match str_of(e.value("tool")) {
    Some(t) => plan_whole(t)
    None => false
  })
}

// ── what is told ──────────────────────────────────────────────────────────────────────────────────────────────────

///|
/// `work` as a fiber of its own, counted by the live view until it ends, whatever it waits for meanwhile (a lookup of
/// Node's included, but for where a session that moved on goes on, `follow_later`): Node is told whether any runs
/// (`pending`), which its `idle` waits for.
fn Actors::lspawn(self : Actors, work : async () -> Unit) -> Unit {
  self.live.pending += 1
  if self.live.pending == 1 {
    self.tell(live_key, "pending", [jbool(true)])
  }
  self.spawn(() => {
    work()
    self.live.pending -= 1
    if self.live.pending == 0 {
      self.tell(live_key, "pending", [jbool(false)])
    }
  })
}

///|
async fn Actors::lnode(self : Actors, f : String, args : Array[Json]) -> Json raise {
  self.rpc(live_key, f, args)
}

///|
fn Actors::llog(self : Actors, level : String, message : String, fields? : Map[String, Json] = {}) -> Unit {
  self.tell(live_key, "log", [jstr(level), jstr(message), Json::object(fields)])
}

///|
/// `message` to `subs` of `key` (Node gives it each, its usage and its entries in brief where a listener has them so;
/// `briefed`: they are already).
fn Actors::ltell(self : Actors, key : String, subs : Array[LSub], message : Json, briefed? : Bool = false) -> Unit {
  if subs.length() == 0 {
    return
  }
  let to = subs.map(s => Json::array([jnum(s.id.to_double()), jbool(s.brief), jbool(s.held)]))
  self.tell(live_key, "told", [jstr(key), Json::array(to), message, jbool(briefed)])
}

///|
fn Actors::lemit(self : Actors, key : String, message : Json) -> Unit {
  let now : Array[LSub] = []
  for sub in self.live.listeners.get(key).unwrap_or([]) {
    match sub.queue {
      Some(q) => q.push(message)
      None => now.push(sub)
    }
  }
  self.ltell(key, now, message)
}

///|
fn timeline(start : Int, entries : Array[Json]) -> Json {
  { "type": jstr("timeline"), "start": jnum(start.to_double()), "entries": Json::array(entries), "usage": Json::null() }
}

///|
/// What it has going in the background and its checklist, as they are now.
fn Actors::work_now(self : Actors, key : String) -> Json {
  let now = self.now
  let tasks = self.live.tasks
    .get(key)
    .unwrap_or([])
    .map(t => {
      let m = match t {
        Object(f) => f.copy()
        _ => {}
      }
      let started = num_of(t.value("startedAt")).unwrap_or(now)
      m["elapsedMs"] = jnum(if now - started > 0.0 { now - started } else { 0.0 })
      Json::object(m)
    })
  let plan = match self.live.said_plans.get(key) {
    Some(p) => p
    None =>
      match self.live.plans.get(key) {
        Some(p) => plan_items(p)
        None => Json::array([])
      }
  }
  { "type": jstr("work"), "tasks": Json::array(tasks), "plan": plan }
}

///|
/// The steps in flight, and the phase.
fn Actors::steps_now(self : Actors, key : String) -> Json {
  let phase = match self.live.phase.get(key) {
    Some((p, at)) => ({ "phase": jstr(p), "elapsedMs": jnum(self.now - at) } : Json)
    None => Json::null()
  }
  { "type": jstr("steps"), "steps": Json::array(self.live.steps.get(key).unwrap_or([]).copy()), "phase": phase }
}

///|
/// A followed session as it is now, for a stream that opens (live.ts `now`).
fn Actors::live_now(self : Actors, key : String) -> Json {
  let out : Array[Json] = []
  if self.live.watched.get(key) is Some(w) && w.tail is Some(tail) {
    out.push(timeline(tail.length(), []))
  }
  out.push(self.steps_now(key))
  out.push(self.work_now(key))
  Json::array(out)
}

// ── a runtime's events ────────────────────────────────────────────────────────────────────────────────────────────

///|
/// A runtime's live event for a session (live.ts `event`).
fn Actors::live_event(self : Actors, key : String, event : Json) -> Unit {
  let l = self.live
  match str_of(event.value("kind")).unwrap_or("") {
    "tasks" => {
      let was : Map[String, Json] = {}
      for t in l.tasks.get(key).unwrap_or([]) {
        if str_of(t.value("id")) is Some(id) && t.value("startedAt") is Some(at) {
          was[id] = at
        }
      }
      let given = match event.value("tasks") {
        Some(Array(t)) => t
        _ => []
      }
      let tasks = given.map(t => {
        let m = match t {
          Object(f) => f.copy()
          _ => {}
        }
        match t.value("startedAt") {
          Some(Number(_, ..)) => ()
          _ =>
            m["startedAt"] = match was.get(str_of(t.value("id")).unwrap_or("")) {
              Some(at) => at
              None => jnum(self.now)
            }
        }
        Json::object(m)
      })
      if tasks.length() == 0 && !l.tasks.contains(key) {
        return
      }
      if tasks.length() == 0 {
        l.tasks.remove(key)
      } else {
        l.tasks[key] = tasks
      }
      self.lemit(key, self.work_now(key))
    }
    "plan" => {
      l.said_plans[key] = event.value("plan").unwrap_or(Json::array([]))
      self.lemit(key, self.work_now(key))
    }
    "phase" => {
      l.phase[key] = (str_of(event.value("phase")).unwrap_or(""), self.now)
      self.lemit(key, { "type": jstr("step"), "event": event })
    }
    "delta" =>
      if str_of(event.value("field")) != Some("output") {
        let id = str_of(event.value("id")).unwrap_or("")
        match num_of(event.value("tokens")) {
          Some(n) => self.counted(key, id, n, true)
          None => self.counted(key, id, tokens_of(str_of(event.value("text")).unwrap_or("")), false)
        }
      }
    "start" => {
      let id = str_of(event.value("id")).unwrap_or("")
      let step = event.value("step").unwrap_or(jstr("text"))
      let input = brief_input(str_of(event.value("input")).unwrap_or(""))
      let steps = l.steps.get(key).unwrap_or([])
      // (started again with its input, as Claude Code streams it after the start: it keeps when it started)
      let started = match steps.search_by(s => str_of(s.value("id")) == Some(id)) {
        Some(i) => steps[i].value("startedAt").unwrap_or(jnum(self.now))
        None => jnum(self.now)
      }
      let kept = steps.filter(s => str_of(s.value("id")) != Some(id))
      let s : Map[String, Json] = { "id": jstr(id), "step": step }
      if event.value("tool") is Some(t) {
        s["tool"] = t
      }
      if event.value("subagent") is Some(True) {
        s["subagent"] = jbool(true)
      }
      if event.value("parent") is Some(p) {
        s["parent"] = p
      }
      s["input"] = jstr(input)
      s["startedAt"] = started
      kept.push(Json::object(s))
      l.steps[key] = kept
      let told : Map[String, Json] = { "kind": jstr("start"), "id": jstr(id), "step": step }
      if event.value("tool") is Some(t) {
        told["tool"] = t
      }
      told["input"] = jstr(input)
      if event.value("subagent") is Some(v) {
        told["subagent"] = v
      }
      if event.value("parent") is Some(p) {
        told["parent"] = p
      }
      self.lemit(key, { "type": jstr("step"), "event": Json::object(told) })
    }
    "end" => {
      let id = str_of(event.value("id")).unwrap_or("")
      guard l.steps.get(key) is Some(steps) else { return }
      let kept = steps.filter(s => str_of(s.value("id")) != Some(id))
      if kept.length() == steps.length() {
        return
      }
      l.steps[key] = kept
      self.lemit(key, { "type": jstr("step"), "event": event })
      // (a step ended: what it wrote no longer counts; once no step's does, the model is not writing)
      if l.rates.get(key) is Some(rate) {
        let now = self.now
        let left : Array[LBucket] = []
        for b in rate.buckets {
          if b.step != id && b.at > now - rate_window_ms {
            left.push(b)
          }
        }
        rate.buckets = left
        rate.last.remove(id)
        if rate.buckets.length() == 0 {
          l.rates.remove(key)
          if rate.told > 0 {
            self.lemit(key, { "type": jstr("rate"), "tokensPerSecond": jnum(0.0) })
          }
        }
      }
      self.lsoon(key)
    }
    _ => ()
  }
}

///|
/// Output written (live.ts `counted`): its rate told once half a second of it has come, then at most once a second.
fn Actors::counted(self : Actors, key : String, id : String, tokens : Double, counted : Bool) -> Unit {
  let now = self.now
  let rate = match self.live.rates.get(key) {
    Some(r) => r
    None => {
      let r = { buckets: [], told_at: 0.0, told: 0, last: Map([]) }
      self.live.rates[key] = r
      r
    }
  }
  let at = (now / 250.0).floor() * 250.0
  if counted {
    let since = match rate.last.get(id) {
      Some(t) => t
      None =>
        match self.live.steps.get(key).unwrap_or([]).search_by(s => str_of(s.value("id")) == Some(id)) {
          Some(i) => num_of(self.live.steps.get(key).unwrap()[i].value("startedAt")).unwrap_or(now)
          None => now
        }
    }
    rate.last[id] = now
    rate.buckets.push({ at, step: id, tokens, since: Some(if since < now { since } else { now }) })
  } else {
    match rate.buckets.search_by(b => b.at == at && b.step == id && b.since is None) {
      Some(i) => rate.buckets[i].tokens += tokens
      None => rate.buckets.push({ at, step: id, tokens, since: None })
    }
  }
  rate.buckets = rate.buckets.filter(b => b.at > now - rate_window_ms)
  if now - rate.told_at < rate_every_ms {
    return
  }
  let mut first = never
  let mut written = never
  let mut counts = never
  let mut total = 0.0
  for b in rate.buckets {
    let s = b.since.unwrap_or(b.at)
    if s < first {
      first = s
    }
    match b.since {
      None => if b.at < written { written = b.at }
      Some(s) => if s < counts { counts = s }
    }
    total += b.tokens
  }
  if rate.told_at == 0.0 && now - first < rate_first_ms {
    return
  }
  let w = if written == never { 0.0 } else { (now - written + 250.0).min(rate_window_ms) }
  let c = if counts == never { 0.0 } else { now - counts }
  let span = w.max(c)
  let per = (total * 1000.0 / span).round()
  let tps = if per < 1.0 { 1 } else { per.to_int() }
  rate.told_at = now
  rate.told = tps
  self.lemit(key, { "type": jstr("rate"), "tokensPerSecond": jnum(tps.to_double()) })
}

///|
/// The turn is over (live.ts `turnEnded`): what it wrote last is read now and told before `clear`.
async fn Actors::live_turn_end(self : Actors, key : String) -> Unit {
  self.live.steps.remove(key)
  self.live.phase.remove(key)
  self.live.rates.remove(key)
  self.read_now(key)
  self.lemit(key, { "type": jstr("clear") })
  self.lsoon(key)
}

///|
/// A turn's end to wait on (`live_turn_end` set going now): the number `on_event` waits on it by.
fn Actors::live_end(self : Actors, key : String) -> Int {
  self.live.next += 1
  let n = self.live.next
  let d : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.live.ends[n] = d
  self.lspawn(() => {
    self.live_turn_end(key)
    ignore(d.succeed(()))
  })
  n
}

///|
/// What `live_end` set going, once it is done.
async fn Actors::live_ended(self : Actors, n : Int) -> Unit {
  guard self.live.ends.get(n) is Some(d) else { return }
  d.wait()
  self.live.ends.remove(n)
}

///|
/// Whether a session is at work (live.ts `running`): followed by the station itself until held_after_ms after it stops.
fn Actors::live_running(self : Actors, key : String, on : Bool) -> Unit {
  let l = self.live
  if on {
    if l.releases.get(key) is Some(release) {
      release()
      l.releases.remove(key)
    }
    if l.holds.contains(key) {
      return
    }
    l.next += 1
    let id = -l.next
    l.holds[key] = id
    self.tell_held()
    self.live_subscribe(key, 9007199254740991.0, None, id, true, held=true)
    return
  }
  if !l.holds.contains(key) || l.releases.contains(key) {
    return
  }
  l.releases[key] = self.after(
    held_after_ms,
    () => {
      l.releases.remove(key)
      if l.holds.get(key) is Some(id) {
        l.holds.remove(key)
        self.tell_held()
        self.live_unsubscribe(key, id)
      }
    },
    on=live_key,
  )
}

///|
/// The sessions followed now, told Node (live.ts `held`, read there at once).
fn Actors::tell_held(self : Actors) -> Unit {
  self.tell(live_key, "held", [Json::array(self.live.holds.keys().map(jstr).collect())])
}

// ── listeners ─────────────────────────────────────────────────────────────────────────────────────────────────────

///|
/// Follows a session (live.ts `subscribe`): the entries from `from` on (only the `last` of them, when given), the
/// usage, the steps in flight, then everything new.
fn Actors::live_subscribe(self : Actors, key : String, from : Double, last : Int?, id : Int, brief : Bool, held? : Bool = false) -> Unit {
  let sub = { id, brief, held, queue: Some([]) }
  let subs = self.live.listeners.get(key).unwrap_or([])
  self.live.listeners[key] = [..subs, sub]
  ignore(self.lwatch(key))
  match self.live.watched.get(key) {
    Some(w) if w.ready => w.waiters.push(() => self.join(key, sub, from, last))
    _ => self.join(key, sub, from, last)
  }
}

///|
fn Actors::listening(self : Actors, key : String, sub : LSub) -> Bool {
  self.live.listeners.get(key).unwrap_or([]).iter().any(s => physical_equal(s, sub))
}

///|
/// A listener told `first`, then what was said while it joined.
fn Actors::joined(self : Actors, key : String, sub : LSub, first : Array[Json], briefed : Bool) -> Unit {
  if !self.listening(key, sub) {
    return
  }
  for m in first {
    self.ltell(key, [sub], m, briefed~)
  }
  let queued = sub.queue.unwrap_or([])
  sub.queue = None
  for m in queued {
    self.ltell(key, [sub], m)
  }
}

///|
/// A listener told what it lacks (live.ts `join`).
fn Actors::join(self : Actors, key : String, sub : LSub, from : Double, last : Int?) -> Unit {
  if !self.listening(key, sub) {
    return
  }
  let tail = match self.live.watched.get(key) {
    Some({ tail: Some(t), .. }) => t
    _ => return self.joined(key, sub, [self.steps_now(key), self.work_now(key)], false)
  }
  let len = tail.length()
  let from = if from > len.to_double() { len } else { from.to_int() }
  let start = match last {
    Some(n) => from.max((len - n).max(0))
    None => from.max(0)
  }
  if start >= len {
    return self.joined(key, sub, [timeline(start, []), self.steps_now(key), self.work_now(key)], false)
  }
  self.lspawn(() => {
    let entries = self.past(key, start, len, sub.brief) catch {
      _ => return self.joined(key, sub, [timeline(len, []), self.steps_now(key), self.work_now(key)], false)
    }
    self.joined(key, sub, [timeline(start, entries), self.steps_now(key), self.work_now(key)], true)
  })
}

///|
/// Entries `from ..< to` of a session's transcripts, read where its history is, in brief or whole.
async fn Actors::past(self : Actors, key : String, from : Int, to : Int, brief : Bool) -> Array[Json] raise {
  let pages : Array[Array[Json]] = []
  let mut upto = to
  while upto > from {
    let page = self.lnode("page", [jstr(key), jnum(upto.to_double()), jnum((upto - from).min(1000).to_double()), jbool(brief)])
    let start = int_of(page.value("start"))
    let entries = match page.value("entries") {
      Some(Array(e)) => e
      _ => []
    }
    let got = entries.iter().take((upto - start).max(0)).collect()
    if got.length() == 0 {
      break
    }
    pages.insert(0, got)
    upto = start
  }
  let out : Array[Json] = []
  for p in pages {
    out.append(p)
  }
  out
}

///|
fn Actors::live_unsubscribe(self : Actors, key : String, id : Int) -> Unit {
  guard self.live.listeners.get(key) is Some(subs) else { return }
  let kept = subs.filter(s => s.id != id)
  if kept.length() > 0 {
    self.live.listeners[key] = kept
    return
  }
  self.live.listeners.remove(key)
  self.unwatch(key, true)
}

// ── following a transcript ────────────────────────────────────────────────────────────────────────────────────────

///|
fn Actors::current_watch(self : Actors, key : String, w : LWatched) -> Bool {
  match self.live.watched.get(key) {
    Some(x) => x.n == w.n
    None => false
  }
}

///|
/// `work` once what was asked to be read of `w` before is done: one read of a tail at a time, in order.
/// One waiting its turn is not counted as the program going on (what it waits for is, or waits on Node in turn); its
/// turn given, it is counted again by the one that gives it, before it runs, so the program is never said quiet between.
async fn Actors::in_read(self : Actors, w : LWatched, work : async () -> Unit raise) -> Unit {
  if w.read_held {
    let turn : @effect.Deferred[Unit] = @effect.Deferred::new()
    w.read_queue.push(turn)
    self.active -= 1
    self.quiet()
    turn.wait()
  } else {
    w.read_held = true
  }
  work() catch {
    e => self.llog("warn", "a transcript could not be read", fields={ "error": jstr(Asked::message(e)) })
  }
  if w.read_queue.length() > 0 {
    let next = w.read_queue.remove(0)
    self.active += 1
    ignore(next.succeed(()))
  } else {
    w.read_held = false
  }
}

///|
/// Where it stands is found (or not): what waited for that runs now, in the order it came.
fn Actors::ready_now(self : Actors, w : LWatched) -> Unit {
  ignore(self)
  if !w.ready {
    return
  }
  w.ready = false
  let waiting = w.waiters.copy()
  w.waiters.clear()
  for f in waiting {
    f()
  }
}

///|
fn Actors::keep_stood(self : Actors, key : String, states : Array[Json]) -> Unit {
  self.live.stood.remove(key)
  self.live.stood[key] = states
  while self.live.stood.length() > 256 {
    guard self.live.stood.keys().next() is Some(first) else { break }
    self.live.stood.remove(first)
  }
}

///|
/// A watched transcript's length, told Node as it changes (its summary says it).
fn Actors::note_length(self : Actors, key : String, tail : LTail) -> Unit {
  let n = tail.length()
  if self.live.length_told.get(key) == Some(n) {
    return
  }
  self.live.length_told[key] = n
  self.tell(live_key, "length", [jstr(key), jnum(n.to_double())])
}

///|
/// What a watched transcript gained, told; the usage counter asked to count it.
fn Actors::gained(self : Actors, key : String, start : Int, entries : Array[Json], grew : Bool) -> Unit {
  if entries.length() == 0 {
    if grew {
      self.tell(live_key, "count", [jstr(key)])
    }
    return
  }
  self.lemit(key, timeline(start, entries))
  self.tell(live_key, "count", [jstr(key)])
  self.read_for_plan(key, start, entries)
}

///|
/// A transcript's entries read for its checklist (live.ts `readForPlan`).
fn Actors::read_for_plan(self : Actors, key : String, start : Int, entries : Array[Json]) -> Unit {
  let l = self.live
  if l.plan_back.get(key) is Some(back) {
    back.append(entries)
    return
  }
  let state = match l.plans.get(key) {
    Some(s) => s
    None => {
      let s = { items: [], creating: Map([]) }
      l.plans[key] = s
      s
    }
  }
  if l.plan_at.get(key) == Some(start) {
    l.plan_at[key] = start + entries.length()
  } else {
    l.plan_at.remove(key)
  }
  if read_plan(state, entries) && !l.said_plans.contains(key) {
    self.lemit(key, self.work_now(key))
  }
}

///|
/// Its checklist as it begins to be watched (live.ts `readPlanBack`): read on from where it was read to before, else
/// back from the latest pages to where a call says it whole (or plan_pages of them); then what was gained meanwhile.
fn Actors::read_plan_back(self : Actors, key : String, end : Int) -> Unit {
  let l = self.live
  let had = l.plans.get(key)
  if had is Some(had) && l.plan_at.get(key) is Some(at) && at <= end && end - at <= plan_page * plan_pages {
    if at == end {
      return
    }
    l.plan_back[key] = []
    self.lspawn(() => {
      let gap : Array[Json] = []
      let ok = try {
        let mut from = at
        while from < end {
          let upto = end.min(from + plan_page)
          let page = self.lnode("page", [jstr(key), jnum(upto.to_double()), jnum((upto - from).to_double()), jbool(false)])
          let entries = match page.value("entries") {
            Some(Array(e)) => e
            _ => []
          }
          let got : Array[Json] = if int_of(page.value("start")) == from {
            entries.iter().take(upto - from).collect()
          } else {
            []
          }
          if got.length() == 0 {
            raise Asked(jstr("not read on"))
          }
          gap.append(got)
          from += got.length()
        }
        true
      } catch {
        _ => false
      }
      if ok {
        self.plan_read(key, Some(end), gap, Some(had))
      } else {
        // (not read on from there: read back)
        l.plan_back.remove(key)
        l.plan_at.remove(key)
        self.read_plan_back(key, end)
      }
    })
    return
  }
  l.plan_back[key] = []
  self.lspawn(() => {
    let pages : Array[Array[Json]] = []
    let ok = try {
      let mut upto = end
      let mut n = 0
      while upto > 0 && n < plan_pages {
        let page = self.lnode("page", [jstr(key), jnum(upto.to_double()), jnum(plan_page.min(upto).to_double()), jbool(false)])
        let start = int_of(page.value("start"))
        let entries = match page.value("entries") {
          Some(Array(e)) => e
          _ => []
        }
        let got = entries.iter().take((upto - start).max(0)).collect()
        if got.length() == 0 {
          break
        }
        pages.insert(0, got)
        upto = start
        n += 1
        if got.iter().any(says_whole) {
          break
        }
      }
      true
    } catch {
      _ => false
    }
    if ok {
      let past : Array[Json] = []
      for p in pages {
        past.append(p)
      }
      self.plan_read(key, Some(end), past, None)
    } else {
      self.plan_read(key, None, [], None)
    }
  })
}

///|
/// Its checklist read from `past` (the entries just before `end`; none: not read) and what was gained meanwhile.
fn Actors::plan_read(self : Actors, key : String, end : Int?, past : Array[Json], from : LPlan?) -> Unit {
  let l = self.live
  let meanwhile = l.plan_back.get(key).unwrap_or([])
  l.plan_back.remove(key)
  let before = match l.plans.get(key) {
    Some(p) => plan_items(p).stringify()
    None => "[]"
  }
  let state = match from {
    Some(s) => s
    None => { items: [], creating: Map([]) }
  }
  ignore(read_plan(state, past))
  ignore(read_plan(state, meanwhile))
  match end {
    Some(e) => l.plan_at[key] = e + meanwhile.length()
    None => l.plan_at.remove(key)
  }
  l.plans[key] = state
  if plan_items(state).stringify() != before && !l.said_plans.contains(key) {
    self.lemit(key, self.work_now(key))
  }
}

///|
/// Watches a session's transcript, once it exists (live.ts `watch`): whether it is watched now. It goes on from where
/// the reading stands (here before, carried over from the process before, or the readers'), else from its start.
fn Actors::lwatch(self : Actors, key : String) -> Bool {
  let l = self.live
  if l.watched.contains(key) {
    return true
  }
  if !l.listeners.contains(key) {
    return false
  }
  l.next += 1
  let w = {
    n: l.next,
    tail: None,
    ready: true,
    waiters: [],
    reading: false,
    behind: false,
    announce: false,
    read_held: false,
    read_queue: [],
    locating: true,
    following: 0,
    follow_again: false,
    carried: None,
    take_up: None,
    armed: None,
  }
  l.watched[key] = w
  let done = () => self.ready_now(w)
  self.lspawn(() => {
    let at = self.lnode("locate", [jstr(key)]) catch {
      e => {
        if self.current_watch(key, w) {
          if w.carried is Some(c) {
            self.keep_stood(key, c)
          }
          self.lgone(key)
          self.llog("warn", "a transcript's location could not be read", fields={ "session": jstr(key), "error": jstr(Asked::message(e)) })
        }
        return done()
      }
    }
    if !self.current_watch(key, w) {
      return done()
    }
    w.locating = false
    if at is Null {
      if w.carried is Some(c) {
        self.keep_stood(key, c)
      }
      self.lgone(key)
      return done()
    }
    self.lstart(key, w, at)
    done()
  })
  true
}

///|
/// A watched session no longer so (its transcript not found).
fn Actors::lgone(self : Actors, key : String) -> Unit {
  self.live.watched.remove(key)
}

///|
/// Begins reading where `at` says its transcripts are (live.ts `start`).
async fn Actors::lstart(self : Actors, key : String, w : LWatched, at : Json) -> Unit {
  let l = self.live
  let runtime = str_of(at.value("runtime")).unwrap_or("claude")
  let paths = match at.value("paths") {
    Some(Array(p)) => p
    _ => []
  }
  w.behind = w.behind || at.value("current") is Some(False)
  let begin = (tail : LTail) => {
    w.tail = Some(tail)
    self.note_length(key, tail)
    self.tell(live_key, "watching", [jstr(key), jbool(true)])
    self.read_plan_back(key, tail.length())
    self.arm(key, w)
  }
  let stood = l.stood.get(key)
  l.stood.remove(key)
  let carried = w.carried
  w.carried = None
  if same_states(stood, at) {
    begin(LTail::from(runtime, stood.unwrap()))
    self.lsoon(key)
    return
  }
  if same_states(carried, at) {
    begin(LTail::from(runtime, carried.unwrap()))
    self.lsoon(key)
    return
  }
  if l.took_tails {
    self.llog("info", "a transcript's reading asked of the readers", fields={ "session": jstr(key), "kept": jbool(stood is Some(_)), "carried": jbool(true) })
  }
  // (begun once: from the readers' answer, or from what the process before carried over, whichever is first)
  let mut begun = false
  w.take_up = Some(states => {
    if begun || !self.current_watch(key, w) || !same_states(Some(states), at) {
      return false
    }
    begun = true
    begin(LTail::from(runtime, states))
    // (the readers not asked once the process before has gone, as they were to be)
    self.tell(live_key, "begun", [jstr(key)])
    // (its listeners join now, not once the readers answer)
    self.ready_now(w)
    self.lsoon(key)
    true
  })
  let states = self.lnode("state", [jstr(key)]) catch { _ => Json::null() }
  w.take_up = None
  if !self.current_watch(key, w) || begun {
    return
  }
  begun = true
  let given = match states {
    Array(s) => Some(s)
    _ => None
  }
  if same_states(given, at) {
    begin(LTail::from(runtime, given.unwrap()))
  } else {
    // (its transcripts are not where the readers found them, or they could not say: read from their start, kept nowhere)
    let tail = LTail::new(runtime, paths)
    let _ = self.read_soon(tail) catch { _ => return }
    if self.current_watch(key, w) {
      begin(tail)
    }
  }
  // (what was written since the readers read it)
  self.lsoon(key)
}

///|
/// Node watches the file written to now (its `.zst` while packed), saying `soon` as it changes.
fn Actors::arm(self : Actors, key : String, w : LWatched) -> Unit {
  guard w.tail is Some(tail) else { return }
  let path = tail.path()
  if w.armed == Some(path) {
    return
  }
  w.armed = Some(path)
  self.tell(live_key, "arm", [jstr(key), jstr(path)])
}

///|
fn Actors::unwatch(self : Actors, key : String, preserve : Bool) -> Unit {
  guard self.live.watched.get(key) is Some(w) else { return }
  if preserve {
    match (w.tail, w.carried) {
      (Some(tail), _) => self.keep_stood(key, tail.snapshot())
      (None, Some(c)) => self.keep_stood(key, c)
      _ => ()
    }
  }
  self.live.watched.remove(key)
  w.following = 0
  w.follow_again = false
  self.tell(live_key, "watching", [jstr(key), jbool(false)])
  if w.armed is Some(_) {
    self.tell(live_key, "disarm", [jstr(key)])
  }
}

///|
/// Reads a watched transcript's new entries now and tells them (live.ts `readNow`).
async fn Actors::read_now(self : Actors, key : String) -> Unit {
  guard self.live.watched.get(key) is Some(w) else { return }
  guard w.tail is Some(_) else { return }
  self.in_read(w, () => {
    guard self.current_watch(key, w) && w.tail is Some(tail) else { return }
    if w.behind {
      // (a turn's last words read before its clear, whatever a lookup still going says)
      self.stop_follow(key, w)
      self.follow_now(key, w)
    }
    let before = tail.read_bytes()
    let (start, entries) = self.read_soon(tail)
    if !self.current_watch(key, w) {
      return
    }
    self.note_length(key, tail)
    self.gained(key, start, entries, tail.read_bytes() != before)
  })
}

///|
/// Goes on into the transcripts a session that moved on has now (live.ts `followSoon`).
async fn Actors::follow_now(self : Actors, key : String, w : LWatched) -> Unit {
  guard w.tail is Some(tail) else { return }
  let at = self.lnode("locate", [jstr(key)]) catch { _ => return }
  if at is Null || !self.current_watch(key, w) {
    return
  }
  w.behind = at.value("current") is Some(False)
  let path = tail.path()
  ignore(tail.go_on(match at.value("paths") { Some(Array(p)) => p; _ => [] }))
  if tail.path() != path {
    self.arm(key, w)
  }
}

///|
/// The lookup going of where it goes on given up (Node told: its answer, late, changes nothing).
fn Actors::stop_follow(self : Actors, key : String, w : LWatched) -> Unit {
  if w.following != 0 {
    self.tell(live_key, "unfollow", [jstr(key)])
  }
  w.following = 0
  w.follow_again = false
}

///|
/// A later read finds where it goes on off the readers (live.ts `followLater`), one lookup at a time.
fn Actors::follow_later(self : Actors, key : String, w : LWatched) -> Unit {
  guard w.tail is Some(_) else { return }
  if w.following != 0 {
    w.follow_again = true
    return
  }
  self.live.next += 1
  let pending = self.live.next
  w.following = pending
  let finished = () => {
    let again = w.follow_again
    w.follow_again = false
    w.following = 0
    if again && w.behind {
      self.follow_later(key, w)
    }
  }
  self.spawn(() => {
    let at = self.lnode("locate", [jstr(key), jbool(true)]) catch {
      e => {
        if self.current_watch(key, w) && w.following == pending {
          w.behind = true
          self.llog("warn", "a transcript's new location could not be read", fields={ "session": jstr(key), "error": jstr(Asked::message(e)) })
          finished()
        }
        return
      }
    }
    self.in_read(w, () => {
      guard self.current_watch(key, w) && w.following == pending && w.tail is Some(tail) else { return }
      if at is Null {
        return finished()
      }
      let path = tail.path()
      let changed = tail.go_on(match at.value("paths") { Some(Array(p)) => p; _ => [] })
      w.behind = at.value("current") is Some(False)
      if tail.path() != path {
        self.arm(key, w)
      }
      finished()
      if changed {
        self.lsoon(key)
      }
    })
  })
}

///|
/// The session went on in a new runtime session (live.ts `moved`): a watched history reads on in its transcript.
fn Actors::live_moved(self : Actors, key : String) -> Unit {
  guard self.live.watched.get(key) is Some(w) else { return }
  guard w.tail is Some(_) else {
    w.behind = true
    return
  }
  self.lspawn(() => {
    self.in_read(w, () => {
      guard self.current_watch(key, w) && w.tail is Some(tail) else { return }
      let before = tail.read_bytes()
      let (start, entries) = self.read_soon(tail)
      if !self.current_watch(key, w) {
        return
      }
      self.gained(key, start, entries, tail.read_bytes() != before)
      // (the new one is usually not written yet: looked for on each read until it is)
      w.behind = true
      self.stop_follow(key, w)
      self.follow_later(key, w)
      self.lsoon(key)
    })
  })
}

///|
/// Reads what the transcript gained, a burst of writes at once (live.ts `soon`).
fn Actors::lsoon(self : Actors, key : String) -> Unit {
  if !self.live.listeners.contains(key) {
    return
  }
  let fresh = !self.live.watched.contains(key)
  if !self.lwatch(key) {
    return
  }
  let w = self.live.watched.get(key).unwrap()
  if fresh {
    w.announce = true
  }
  if w.reading {
    return
  }
  w.reading = true
  ignore(
    self.after(
      40.0,
      () => {
        guard self.live.watched.get(key) is Some(now) else { return }
        now.reading = false
        guard now.tail is Some(_) else {
          // (where it stands still asked: read on once it is)
          if now.ready {
            now.waiters.push(() => if self.current_watch(key, now) && now.tail is Some(_) { self.lsoon(key) })
          }
          return
        }
        let announce = now.announce
        now.announce = false
        if now.behind {
          self.follow_later(key, now)
        }
        self.lspawn(() => {
          self.in_read(now, () => {
            guard self.current_watch(key, now) && now.tail is Some(tail) else { return }
            let before = tail.read_bytes()
            let (start, entries) = self.read_soon(tail)
            if !self.current_watch(key, now) {
              return
            }
            self.note_length(key, tail)
            self.gained(key, start, entries, tail.read_bytes() != before)
            if entries.length() == 0 && announce {
              self.lemit(key, timeline(start, entries))
            }
          })
        })
      },
      on=live_key,
    ),
  )
}

///|
/// Its usage changed (Node's counter: usage/module.ts): where its transcript ends told with it.
fn Actors::live_usage(self : Actors, key : String) -> Unit {
  if self.live.watched.get(key) is Some({ tail: Some(tail), .. }) {
    self.lemit(key, timeline(tail.length(), []))
  }
}

///|
/// A deleted session: nothing of it watched or kept any more.
fn Actors::live_forget(self : Actors, key : String) -> Unit {
  let l = self.live
  l.tasks.remove(key)
  l.plans.remove(key)
  l.plan_at.remove(key)
  l.stood.remove(key)
  l.plan_back.remove(key)
  l.said_plans.remove(key)
  l.steps.remove(key)
  l.phase.remove(key)
  l.rates.remove(key)
  self.lemit(key, { "type": jstr("clear") })
  if l.releases.get(key) is Some(release) {
    release()
    l.releases.remove(key)
  }
  if l.holds.contains(key) {
    l.holds.remove(key)
    self.tell_held()
  }
  l.length_told.remove(key)
  l.listeners.remove(key)
  self.unwatch(key, false)
}

// ── carried over at a handover ───────────────────────────────────────────────────────────────────────────────────

///|
/// The checklists read from transcripts and how far each was read (live.ts `carriedPlans`).
fn Actors::carried_plans(self : Actors) -> Json {
  let out : Array[Json] = []
  for key, at in self.live.plan_at {
    guard self.live.plans.get(key) is Some(state) && !self.live.plan_back.contains(key) else { continue }
    let creating : Array[Json] = []
    for id, made in state.creating {
      match state.items.search_by(i => physical_equal(i, made)) {
        Some(i) => creating.push(Json::array([jstr(id), jnum(i.to_double())]))
        None => ()
      }
    }
    let items = state.items.map(i => {
      let m : Map[String, Json] = { "text": jstr(i.text), "status": jstr(i.status) }
      if i.id is Some(id) {
        m["id"] = jstr(id)
      }
      Json::object(m)
    })
    out.push({ "key": jstr(key), "at": jnum(at.to_double()), "items": Json::array(items), "creating": Json::array(creating) })
  }
  Json::array(out)
}

///|
/// What the process before read of checklists, where none is read here yet (live.ts `takePlans`).
fn Actors::take_plans(self : Actors, carried : Json) -> Unit {
  guard carried is Array(list) else { return }
  for c in list {
    guard str_of(c.value("key")) is Some(key) && c.value("at") is Some(Number(at, ..)) else { continue }
    guard c.value("items") is Some(Array(items)) && c.value("creating") is Some(Array(creating)) else { continue }
    if self.live.plans.contains(key) || self.live.plan_back.contains(key) {
      continue
    }
    let items = items.map(i => { text: str_of(i.value("text")).unwrap_or(""), status: str_of(i.value("status")).unwrap_or("pending"), id: str_of(i.value("id")) })
    let made : Map[String, PItem] = {}
    for p in creating {
      if p is Array([String(id), Number(at, ..)]) && at.to_int() >= 0 && at.to_int() < items.length() {
        made[id] = items[at.to_int()]
      }
    }
    self.live.plans[key] = { items, creating: made }
    self.live.plan_at[key] = at.to_int()
  }
}

///|
/// Where the reading of each transcript stands here, watched or not (live.ts `carriedTails`).
fn Actors::carried_tails(self : Actors) -> Json {
  let out : Map[String, Array[Json]] = {}
  for key, states in self.live.stood {
    out[key] = states
  }
  for key, w in self.live.watched {
    match (w.tail, w.carried) {
      (Some(tail), _) => out[key] = tail.snapshot()
      (None, Some(c)) => out[key] = c
      _ => ()
    }
  }
  Json::array(out.iter().map(kv => ({ "key": jstr(kv.0), "states": Json::array(kv.1) } : Json)).collect())
}

///|
/// What the process before read of transcripts, where none is watched here yet (live.ts `takeTails`).
fn Actors::take_tails(self : Actors, carried : Json) -> Unit {
  guard carried is Array(list) else { return }
  let mut taken = 0
  let mut watched = 0
  for c in list {
    guard str_of(c.value("key")) is Some(key) && c.value("states") is Some(Array(states)) else { continue }
    let whole = states.iter().all(st => str_of(st.value("path")) is Some(_) && st.value("offset") is Some(Number(_, ..)) && st.value("count") is Some(Number(_, ..)))
    if !whole {
      continue
    }
    match self.live.watched.get(key) {
      Some(w) =>
        if w.tail is None && w.locating && w.carried is None {
          w.carried = Some(states)
          taken += 1
        } else if w.tail is None && (match w.take_up { Some(f) => f(states); None => false }) {
          taken += 1
        } else {
          watched += 1
        }
      None => {
        self.keep_stood(key, states)
        taken += 1
      }
    }
  }
  self.live.took_tails = true
  self.llog("info", "transcripts' readings taken up", fields={ "carried": jnum(list.length().to_double()), "taken": jnum(taken.to_double()), "watched": jnum(watched.to_double()) })
}

// ── what Node asks ────────────────────────────────────────────────────────────────────────────────────────────────

///|
/// Node's calls of the live view (live.ts): each done as it comes, in order; what waits (a turn's end) after.
fn Actors::live_called(self : Actors, id : Double, method : String, args : Array[Json]) -> Unit {
  let arg = (i : Int) => if i < args.length() { args[i] } else { Json::null() }
  let key = str_of(Some(arg(0))).unwrap_or("")
  let answer = (value : Json) => self.say_node({ "returned": jnum(id), "value": value })
  match method {
    "event" => {
      self.live_event(key, arg(1))
      answer(Json::null())
    }
    "turnEnded" =>
      self.lspawn(() => {
        self.live_turn_end(key)
        answer(Json::null())
      })
    "running" => {
      self.live_running(key, arg(1) is True)
      answer(Json::null())
    }
    "subscribe" => {
      let from = num_of(Some(arg(1))).unwrap_or(0.0)
      let last = match arg(2) {
        Number(n, ..) => Some(n.to_int())
        _ => None
      }
      self.live_subscribe(key, from, last, int_of(Some(arg(3))), arg(4) is True)
      answer(Json::null())
    }
    "unsubscribe" => {
      self.live_unsubscribe(key, int_of(Some(arg(1))))
      answer(Json::null())
    }
    "soon" => {
      self.lsoon(key)
      answer(Json::null())
    }
    "moved" => {
      self.live_moved(key)
      answer(Json::null())
    }
    "forget" => {
      self.live_forget(key)
      answer(Json::null())
    }
    "usage" => {
      self.live_usage(key)
      answer(Json::null())
    }
    "now" => {
      let out : Map[String, Json] = {}
      match arg(0) {
        Array(keys) =>
          for k in keys {
            if str_of(Some(k)) is Some(k) {
              out[k] = self.live_now(k)
            }
          }
        _ => ()
      }
      answer(Json::object(out))
    }
    "carried" => answer({ "plans": self.carried_plans(), "tails": self.carried_tails() })
    "takePlans" => {
      self.take_plans(arg(0))
      answer(Json::null())
    }
    "takeTails" => {
      self.take_tails(arg(0))
      answer(Json::null())
    }
    _ => answer(Json::null())
  }
}
