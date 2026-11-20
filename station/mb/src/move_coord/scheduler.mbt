// The scheduler of a migration (station/src/move/scheduler.ts; move/AGENTS.md): it only orders the modules' items and
// never does a module's work. An item moves once what it needs is there (refused naming what it waits for, or, asked
// `withNeeds`, those move first); it is moved back once nothing on the other station that needs it is still there. As
// an item moves away, each item still here that needs it and cannot have it here any more is stopped (`stopped.log`,
// kept across starts), and goes on as what it waits for is back, or as it moves itself. What changes is told.

///|
/// Which items: one (`module` and `item`), a module's (`module`), or all (`all`); `with_needs`: what they need first;
/// `follow`: the items of these modules that need only what moved go with it; `arrive_stopped`: an item whose need is
/// not there goes all the same, arriving there stopped.
pub(all) struct Selection {
  module : String?
  item : String?
  all : Bool
  with_needs : Bool
  follow : Array[String]?
  arrive_stopped : Bool
}

///|
pub fn Selection::of(j : J) -> Selection {
  {
    module: text(get(Some(j), "module")),
    item: text(get(Some(j), "item")),
    all: is_true(get(Some(j), "all")),
    with_needs: is_true(get(Some(j), "withNeeds")),
    follow: arr(get(Some(j), "follow")).map(a => a.filter_map(x => text(Some(x)))),
    arrive_stopped: is_true(get(Some(j), "arriveStopped")),
  }
}

///|
pub(all) struct SchedulerDeps {
  data : String
  disk : Disk
  clock : Clock
  say : Say
  modules : Array[Module]
  changed : (() -> Unit)?
  progress : ((Need, J) -> Unit)?
  tell_arrived : (async (String, Need) -> Unit)?
  now : (() -> Double)?
  refusal : (async (String, String) -> String?)?
  room_for_all : (async (String, String, J) -> String?)?
  hold : (() -> (() -> Unit))?
  restarted : (() -> String)?
  reads : ((String) -> PlanReads)?
  turn : ((Bool, String) -> Unit)?
}

///|
/// An item stopped here, kept: what it waits for, of which workspace.
priv struct Stopped {
  item : Need
  waits_for : Waits
  ws : String
  /// As it is kept (`{item, waitsFor, ws}`, or the record of before as it was).
  raw : J
}

///|
fn Stopped::of(j : J) -> Stopped {
  {
    item: need_of(get(Some(j), "item").unwrap_or(jo([]))),
    waits_for: waits_of(get(Some(j), "waitsFor").unwrap_or(jo([]))),
    ws: text(get(Some(j), "ws")).unwrap_or(""),
    raw: j,
  }
}

///|
fn Stopped::new(item : Need, waits_for : Waits, ws : String) -> Stopped {
  {
    item,
    waits_for,
    ws,
    raw: jo([("item", item.to_j()), ("waitsFor", waits_for.to_j()), ("ws", js(ws))]),
  }
}

///|
fn need_key(s : Stopped) -> String {
  "\{s.waits_for.need().named()}\t\{s.waits_for.at.unwrap_or("")}\t\{s.ws}"
}

///|
priv struct NeedCount {
  waits_for : Waits
  ws : String
  mut n : Int
}

///|
/// What is stopped here (`stopped.log`, a line an item stopped or let go), by each item's name and by what it waits
/// for: each lookup a map's, each change written alone.
priv struct StoppedSet {
  by : Map[String, Stopped]
  waiting : Map[String, Array[String]]
  needs : Map[String, NeedCount]
  log : KeptLog
  writing : Array[@effect.Deferred[Unit]]
  spawn : (async () -> Unit) -> Unit
  say : Say
  mut looked : Int
}

///|
fn StoppedSet::new(log : KeptLog, spawn : (async () -> Unit) -> Unit, say : Say) -> StoppedSet {
  let s = { by: {}, waiting: {}, needs: {}, log, writing: [], spawn, say, looked: 0 }
  for v in log.values() {
    ignore(s.keep(Stopped::of(v)))
  }
  s
}

///|
async fn StoppedSet::written(self : StoppedSet) -> Unit {
  let now = self.writing.copy()
  for d in now {
    d.wait()
  }
}

///|
fn StoppedSet::write(self : StoppedSet, f : async () -> Unit) -> Unit {
  let done = @effect.Deferred::new()
  self.writing.push(done)
  (self.spawn)(async fn() {
    f() catch {
      e =>
        self.say.log(
          "warn",
          "a stopped item's change not written",
          jo([("error", js(message_of(e)))]),
        )
    }
    match self.writing.search_by(x => physical_equal(x, done)) {
      Some(i) => ignore(self.writing.remove(i))
      None => ()
    }
    ignore(done.succeed(()))
  })
}

///|
fn StoppedSet::add(self : StoppedSet, s : Stopped) -> Unit {
  if !self.keep(s) {
    return
  }
  self.write(self.log.set_soon(s.item.named(), s.raw))
}

///|
fn StoppedSet::keep(self : StoppedSet, s : Stopped) -> Bool {
  let k = s.item.named()
  if self.by.contains(k) {
    return false
  }
  self.by[k] = s
  let w = s.waits_for.need().named()
  match self.waiting.get(w) {
    Some(set) => if !set.contains(k) { set.push(k) }
    None => self.waiting[w] = [k]
  }
  let nk = need_key(s)
  match self.needs.get(nk) {
    Some(n) => n.n += 1
    None => self.needs[nk] = { waits_for: s.waits_for, ws: s.ws, n: 1 }
  }
  true
}

///|
fn StoppedSet::has(self : StoppedSet, item : Need) -> Bool {
  self.by.contains(item.named())
}

///|
fn StoppedSet::get(self : StoppedSet, item : Need) -> Stopped? {
  self.by.get(item.named())
}

///|
fn StoppedSet::remove(self : StoppedSet, item : Need) -> Stopped? {
  let k = item.named()
  let s = match self.by.get(k) {
    Some(s) => s
    None => return None
  }
  self.by.remove(k)
  match self.waiting.get(s.waits_for.need().named()) {
    Some(set) =>
      match set.search(k) {
        Some(i) => ignore(set.remove(i))
        None => ()
      }
    None => ()
  }
  match self.needs.get(need_key(s)) {
    Some(n) => {
      n.n -= 1
      if n.n == 0 {
        self.needs.remove(need_key(s))
      }
    }
    None => ()
  }
  match self.log.delete_soon(k) {
    Some(f) => self.write(f)
    None => self.write(async fn() {  })
  }
  Some(s)
}

///|
fn StoppedSet::needs_at(self : StoppedSet, at : String?) -> Array[(Waits, String)] {
  self.looked += self.needs.length()
  let out = []
  for _, n in self.needs {
    if at is None || n.waits_for.at is None || n.waits_for.at == at {
      out.push((n.waits_for, n.ws))
    }
  }
  out
}

///|
fn StoppedSet::waiting_for(self : StoppedSet, n : Need) -> Array[Stopped] {
  let keys = self.waiting.get(n.named()).unwrap_or([])
  self.looked += keys.length()
  keys.filter_map(k => self.by.get(k))
}

///|
fn StoppedSet::values(self : StoppedSet) -> Array[Stopped] {
  self.looked += self.by.length()
  self.by.values().collect()
}

///|
/// Items by what names them and by what they need, made once for a plan or a turn.
pub struct Items {
  priv by : Map[String, J]
  priv needing : Map[String, Array[J]]
}

///|
pub fn Items::new(items : Array[J]) -> Items {
  let by = {}
  let needing : Map[String, Array[J]] = {}
  for x in items {
    if !by.contains(item_named(x)) {
      by[item_named(x)] = x
    }
  }
  for x in items {
    let seen : Set[String] = Set::new()
    for n in item_needs(x) {
      let k = n.named()
      if seen.contains(k) {
        continue
      }
      seen.add(k)
      match needing.get(k) {
        Some(list) => list.push(x)
        None => needing[k] = [x]
      }
    }
  }
  { by, needing }
}

///|
pub fn Items::find(self : Items, n : Need) -> J? {
  self.by.get(n.named())
}

///|
pub fn Items::needing(self : Items, n : Need) -> Array[J] {
  self.needing.get(n.named()).unwrap_or([])
}

///|
/// The turn under way's plan as a page reads it (`held`).
pub struct Held {
  ws : String
  to : String
  plan : J
  by_module : Map[String, Array[J]]
  at : Map[String, Int]
  counts : Map[String, (Int, Int, Int)]
}

///|
pub struct Scheduler {
  priv d : SchedulerDeps
  priv modules : Map[String, Module]
  priv order : Array[String]
  priv stopped : StoppedSet
  priv turn_lock : @effect.Semaphore
  priv mut asked : Int
  priv mut last : J
  priv mut stopping : J?
  priv mut current : Need?
  /// The item as the turn has it (its plan's row, as the TypeScript's `current()` gives it).
  priv mut current_item : J?
  priv mut settling : @effect.Deferred[Array[Need]]?
  priv mut bringing : Set[String]
  priv mut held : Held?
  priv running : Array[@effect.Deferred[Unit]]
}

///|
fn stopped_file(data : String) -> String {
  @nodepath.join("/", [data, "move", "stopped.log"])
}

///|
fn stopped_before(data : String) -> String {
  @nodepath.join("/", [data, "move", "stopped.json"])
}

///|
fn last_file(data : String) -> String {
  @nodepath.join("/", [data, "move", "last.json"])
}

///|
fn turn_file(data : String) -> String {
  @nodepath.join("/", [data, "move", "turn.json"])
}

///|
pub fn Scheduler::new(d : SchedulerDeps) -> Scheduler raise MoveError {
  let modules = {}
  let order = []
  for m in d.modules {
    if modules.contains(m.id) {
      raise Failed("two modules \{m.id}")
    }
    modules[m.id] = m
    order.push(m.id)
  }
  for m in d.modules {
    for n in m.needs {
      if !modules.contains(n) {
        raise Failed("module \{m.id} needs \{n}, which is not one")
      }
    }
  }
  let log = KeptLog::new(d.disk, stopped_file(d.data), from=(stopped_before(d.data), raw => match raw {
    Arr(xs) => xs.map(s => (need_of(get(Some(s), "item").unwrap_or(jo([]))).named(), s))
    _ => []
  }))
  let last = match (d.disk.read)(last_file(d.data)) {
    Some(t) =>
      match (try Ok(parse(t)) catch { e => Err(e) }) {
        Ok(j) => j
        Err(_) => jo([])
      }
    None => jo([])
  }
  {
    d,
    modules,
    order,
    stopped: StoppedSet::new(log, d.clock.spawn, d.say),
    turn_lock: @effect.Semaphore::new(1),
    asked: 0,
    last,
    stopping: None,
    current: None,
    current_item: None,
    settling: None,
    bringing: Set::new(),
    held: None,
    running: [],
  }
}

///|
fn Scheduler::say(self : Scheduler, key : String, args : Array[(String, String)]) -> String {
  self.d.say.tr("station.move.sched.\{key}", args)
}

///|
/// An item as people call it: what it is (its module's word) and its label, never its id.
pub fn called(s : Say, module : String, label : String) -> String {
  let l = if module == "chats" && label.has_prefix("chat:") {
    slice_from(label, 5)
  } else {
    label
  }
  s.tr("station.move.called", [
    ("what", s.tr("station.move.module.\{module}", [])),
    ("label", l),
  ])
}

///|
fn Scheduler::called(self : Scheduler, x : J) -> String {
  called(self.d.say, item_module(x), item_label(x))
}

///|
fn Scheduler::changed(self : Scheduler) -> Unit {
  match self.d.changed {
    Some(f) => f()
    None => ()
  }
}

///|
/// Once the turns asked so far are over (a test's).
pub async fn Scheduler::settle(self : Scheduler) -> Unit {
  while self.running.length() > 0 {
    for d in self.running.copy() {
      d.wait()
    }
  }
}

///|
/// The turn under way asked to stop by `by`: nothing further of it starts, the item under way gives up where it can.
pub fn Scheduler::stop_turn(self : Scheduler, by : String?) -> Bool {
  if !self.busy() {
    return false
  }
  if self.stopping is None {
    self.stopping = Some(match by {
      Some(b) => js(b)
      None => Null
    })
  }
  for id in self.order {
    match self.modules[id].abandon {
      Some(f) => f()
      None => ()
    }
  }
  self.changed()
  true
}

///|
pub fn Scheduler::stopping(self : Scheduler) -> Bool {
  self.stopping is Some(_)
}

///|
/// The item the turn under way is at.
pub fn Scheduler::current(self : Scheduler) -> Need? {
  self.current
}

///|
/// The item the turn under way is at, whole (its plan's row).
pub fn Scheduler::current_item(self : Scheduler) -> J? {
  self.current_item
}

///|
pub fn Scheduler::busy(self : Scheduler) -> Bool {
  self.asked > 0
}

///|
/// `ws`'s last move or move back that ended here.
pub fn Scheduler::last(self : Scheduler, ws : String) -> J? {
  match get(Some(self.last), ws) {
    Some(Null) | None => None
    Some(l) => Some(l)
  }
}

///|
/// Begun: what was stopped is stopped again.
pub async fn Scheduler::start(self : Scheduler) -> Unit {
  match (self.d.disk.read)(turn_file(self.d.data)) {
    Some(t) => {
      let cut = parse(t)
      let error = match self.d.restarted {
        Some(f) => f()
        None =>
          "the station restarted during the move: what moved stays moved; ask again to go on"
      }
      let pairs = [("at", jn(self.now()))]
      match get(Some(cut), "by") {
        Some(b) => pairs.push(("by", b))
        None => ()
      }
      match get(Some(cut), "how") {
        Some(b) => pairs.push(("how", b))
        None => ()
      }
      match get(Some(cut), "station") {
        Some(b) => pairs.push(("station", b))
        None => ()
      }
      pairs.push(("done", ja([])))
      pairs.push(("refused", ja([])))
      pairs.push(("stopped", ja([])))
      pairs.push(("resumed", ja([])))
      pairs.push(("failed", jo([("item", Null), ("error", js(error))])))
      self.keep_last(text(get(Some(cut), "ws")).unwrap_or(""), jo(pairs))
      (self.d.disk.remove)(turn_file(self.d.data))
    }
    None => ()
  }
  ignore(self.settle_stopped())
  let moved = []
  for s in self.stopped.values() {
    match self.modules.get(s.item.module) {
      Some(m) => {
        let state = (m.state)(bare_item(s.item.module, s.item.id, []))
        if state_name(state) == "there" {
          moved.push(s)
        }
      }
      None => ()
    }
  }
  if moved.length() > 0 {
    self.let_go(moved, false)
  }
  for s in self.stopped.values() {
    match self.modules.get(s.item.module) {
      Some({ stop: Some(stop), .. }) =>
        stop(bare_item(s.item.module, s.item.id, [s.waits_for]), s.waits_for) catch {
          e =>
            self.d.say.log(
              "warn",
              "an item not stopped again",
              jo([("item", js(s.item.named())), ("error", js(message_of(e)))]),
            )
        }
      _ => ()
    }
  }
}

///|
fn Scheduler::now(self : Scheduler) -> Double {
  match self.d.now {
    Some(f) => f()
    None => 0.0
  }
}

///|
/// The items stopped here whose need is here let go (as the station starts, and as a station an item came from is
/// heard again). `from`: only what waits for what is at that station; `module`: only what waits for that module's.
pub async fn Scheduler::settle_stopped(
  self : Scheduler,
  from? : String,
  module? : String,
) -> Array[Need] {
  while self.settling is Some(s) {
    if module is None {
      return s.wait()
    }
    ignore(try Ok(s.wait()) catch { e => Err(e) })
  }
  let done : @effect.Deferred[Array[Need]] = @effect.Deferred::new()
  self.settling = Some(done)
  let r = try Ok({
    let going : Array[Need] = []
    let plans : Map[String, Items?] = {}
    for p in self.stopped.needs_at(from) {
      let (waits_for, ws) = p
      if module is Some(m) && waits_for.module != m {
        continue
      }
      if self.current is Some(c) && c.named() == waits_for.need().named() {
        continue
      }
      let m = self.modules.get(waits_for.module)
      let bare = bare_item(waits_for.module, waits_for.id, [])
      let waiting = () => self.stopped
        .waiting_for(waits_for.need())
        .filter(s => s.ws == ws)
        .map(s => s.item)
      match m {
        Some({ is_here: Some(is_here), usable_here, .. }) => {
          let here = is_here(bare) ||
            (match usable_here {
              Some(u) => u(bare)
              None => false
            })
          if here {
            going.push_iter(waiting().iter())
          }
          continue
        }
        _ => ()
      }
      if !plans.contains(ws) {
        let plan = try Ok(self.plan(ws, "")) catch { e => Err(e) }
        plans[ws] = match plan {
          Ok(p) => Some(Items::new(arr(get(Some(p), "items")).unwrap_or([])))
          Err(_) => None
        }
      }
      match plans.get(ws) {
        Some(Some(items)) =>
          match items.find(waits_for.need()) {
            Some(x) => {
              let s = state_name(x)
              let usable = match m {
                Some({ usable_here: Some(u), .. }) => u(x)
                _ => false
              }
              if s == "here" || s == "failed" || usable {
                going.push_iter(waiting().iter())
              }
            }
            None => ()
          }
        _ => ()
      }
    }
    let ours = going
      .filter_map(g => self.stopped.get(g))
      .filter(s => !self.bringing.contains(s.waits_for.need().named()))
    let going = ours.map(s => s.item)
    if going.length() > 0 {
      self.let_go(ours, true)
      self.changed()
    }
    going
  }) catch { e => Err(e) }
  self.settling = None
  match r {
    Ok(v) => {
      ignore(done.succeed(v))
      v
    }
    Err(e) => {
      ignore(done.fail(e))
      raise e
    }
  }
}

///|
/// Whether anything is stopped here (waiting for what is at `at`, where given).
pub fn Scheduler::has_stopped(self : Scheduler, at? : String) -> Bool {
  self.stopped.needs_at(at).length() > 0
}

///|
/// Whether anything stopped here waits for an item of module `module`.
pub fn Scheduler::waits_on(self : Scheduler, module : String) -> Bool {
  self.stopped.needs_at(None).iter().any(n => n.0.module == module)
}

///|
/// What waits for what here.
pub fn Scheduler::stopped_list(self : Scheduler) -> Array[(Need, Waits)] {
  self.stopped.values().map(s => (s.item, s.waits_for))
}

///|
/// The plan as an agent reads it: while a turn toward `to` runs, the turn's own plan, each item where it stands now.
pub async fn Scheduler::plan_shown(self : Scheduler, ws : String, to : String) -> J {
  match self.held {
    Some(h) if h.ws == ws && h.to == to => {
      let items = []
      for x in arr(get(Some(h.plan), "items")).unwrap_or([]) {
        items.push(self.now_of(x))
      }
      set(h.plan, "items", ja(items))
    }
    _ => self.plan(ws, to)
  }
}

///|
/// The turn under way's own plan, for a page read while it runs (None: no turn toward `to` of `ws` runs).
pub fn Scheduler::held(self : Scheduler, ws : String, to : String) -> Held? {
  match self.held {
    Some(h) if h.ws == ws && h.to == to => Some(h)
    _ => None
  }
}

///|
/// Item `x` of the turn's plan as it stands now.
pub async fn Scheduler::now_of(self : Scheduler, x : J) -> J {
  let mut item = x
  for k in ["state", "error", "progress", "waitsFor", "at", "waits", "from", "lentTo"] {
    item = del(item, k)
  }
  let st = self.state_of(item)
  let at = text(get(Some(st), "at"))
  let mut out = spread(item, del(st, "at"))
  match at {
    Some(a) if Some(a) != self.held.map(h => h.to) => out = set(out, "at", js(a))
    _ => ()
  }
  set(out, "wouldStop", get(Some(x), "wouldStop").unwrap_or(ja([])))
}

///|
fn Scheduler::hold_plan(self : Scheduler, ws : String, to : String, plan : J) -> Unit {
  let by_module : Map[String, Array[J]] = {}
  let at = {}
  let counts : Map[String, (Int, Int, Int)] = {}
  for x in arr(get(Some(plan), "items")).unwrap_or([]) {
    let m = item_module(x)
    let list = match by_module.get(m) {
      Some(l) => l
      None => {
        let l = []
        by_module[m] = l
        l
      }
    }
    at[item_named(x)] = list.length()
    list.push(x)
    let (done, total, cannot) = counts.get(m).unwrap_or((0, 0, 0))
    let s = state_name(x)
    let done = if s == "there" { done + 1 } else { done }
    let cannot = if s != "there" && s == "here" && item_cannot(x) is Some(_) {
      cannot + 1
    } else {
      cannot
    }
    counts[m] = (done, total + 1, cannot)
  }
  self.held = Some({ ws, to, plan, by_module, at, counts })
}

///|
fn Scheduler::ended(self : Scheduler, x : Need, there : Int) -> Unit {
  match self.held {
    Some(h) =>
      match h.counts.get(x.module) {
        Some((done, total, cannot)) => {
          let d = done + there
          let d = if d > total { total } else { d }
          let d = if d < 0 { 0 } else { d }
          h.counts[x.module] = (d, total, cannot)
        }
        None => ()
      }
    None => ()
  }
}

///|
/// What a move of `ws` to `to` would be: every module's items, where each stands, what each would stop.
pub async fn Scheduler::plan(self : Scheduler, ws : String, to : String) -> J {
  let items : Array[J] = []
  let reads = self.d.reads.map(f => f(ws))
  match reads {
    Some(r) => (r.load)()
    None => ()
  }
  let mut first = true
  for id in self.order {
    let m = self.modules[id]
    if !first {
      @effect.pause()
    }
    first = false
    for item in (m.plan)(ws, to, reads) {
      for n in item_needs(item) {
        if !m.needs.contains(n.module) {
          raise Failed(
            "module \{m.id}'s item \{item_id(item)} needs \{n.named()}, of a module it does not declare",
          )
        }
      }
      items.push(item)
    }
  }
  let cycles = item_cycles(items.filter(x => item_cannot(x) is None))
  for at in 0..<items.length() {
    let x = items[at]
    if item_cannot(x) is None {
      match cycles.get(item_named(x)) {
        Some(chain) =>
          items[at] = set(
            x,
            "cannot",
            js(
              self.say("cycle", [
                ("chain", chain.map(y => self.called(y)).join(" → ")),
              ]),
            ),
          )
        None => ()
      }
    }
  }
  let planned : Array[J] = []
  for item in items {
    let st = self.state_of(item)
    let at = text(get(Some(st), "at"))
    let mut p = spread(item, del(st, "at"))
    match at {
      Some(a) if a != to => p = set(p, "at", js(a))
      _ => ()
    }
    planned.push(set(p, "wouldStop", ja([])))
  }
  let index = Items::new(planned)
  for i in 0..<planned.length() {
    let p = planned[i]
    let m = self.modules[item_module(p)]
    if state_name(p) == "there" {
      continue
    }
    let usable = match m.usable_here {
      Some(u) => u(p)
      None => false
    }
    if usable {
      continue
    }
    let stops = index
      .needing(item_need(p))
      .filter(x => state_name(x) != "there" && self.stoppable(item_module(x)))
      .map(x => item_need(x).to_j())
    planned[i] = set(p, "wouldStop", ja(stops))
  }
  let modules = self.order.map(id => jo([
    ("id", js(id)),
    ("needs", jstrs(self.modules[id].needs)),
  ]))
  jo([
    ("ws", js(ws)),
    ("to", js(to)),
    ("modules", ja(modules)),
    ("items", ja(planned)),
  ])
}

///|
/// Whether an item that needs what moves away is stopped by it: only one whose module stops its items.
fn Scheduler::stoppable(self : Scheduler, module : String) -> Bool {
  match self.modules.get(module) {
    Some({ stop: Some(_), .. }) => true
    _ => false
  }
}

///|
async fn Scheduler::state_of(self : Scheduler, item : J) -> J {
  let st = (self.modules[item_module(item)].state)(item)
  match self.stopped.get(item_need(item)) {
    Some(s) if state_name(st) == "here" =>
      set(set(st, "state", js("stopped")), "waitsFor", s.waits_for.to_j())
    _ => st
  }
}

///|
/// Moves what `sel` names of `ws` to `to`, in the order their needs make; `by`: who asked. Asked at once (`busy` from
/// now), its outcome given by what is given back.
pub fn Scheduler::move_soon(
  self : Scheduler,
  ws : String,
  to : String,
  sel : Selection,
  by : String?,
) -> @effect.Deferred[J] {
  self.queue(ws, "move", to, by, async fn() { self.move_turn(ws, to, sel) })
}

///|
/// Moves back what `sel` names of `ws` from `from`, in the reverse order.
pub fn Scheduler::back_soon(
  self : Scheduler,
  ws : String,
  from : String,
  sel : Selection,
  by : String?,
) -> @effect.Deferred[J] {
  self.queue(ws, "back", from, by, async fn() { self.back_turn(ws, from, sel) })
}

///|
pub async fn Scheduler::move(
  self : Scheduler,
  ws : String,
  to : String,
  sel : Selection,
  by? : String,
) -> J {
  self.move_soon(ws, to, sel, by).wait()
}

///|
pub async fn Scheduler::back(
  self : Scheduler,
  ws : String,
  from : String,
  sel : Selection,
  by? : String,
) -> J {
  self.back_soon(ws, from, sel, by).wait()
}

///|
fn by_j(by : String?) -> J {
  match by {
    Some(b) => js(b)
    None => Null
  }
}

///|
/// One turn after the others, its outcome kept as `ws`'s last.
fn Scheduler::queue(
  self : Scheduler,
  ws : String,
  how : String,
  station : String,
  by : String?,
  f : async () -> J,
) -> @effect.Deferred[J] {
  self.asked += 1
  let out : @effect.Deferred[J] = @effect.Deferred::new()
  let ran : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.running.push(ran)
  (self.d.clock.spawn)(async fn() {
    self.turn_lock.acquire()
    let let_go : Ref[(() -> Unit)?] = Ref(None)
    let r = try Ok({
      match self.d.refusal {
        Some(refusal) =>
          match refusal(ws, station) {
            Some(why) if why != "" => raise Said(why)
            _ => ()
          }
        None => ()
      }
      let_go.val = self.d.hold.map(h => h())
      match self.d.turn {
        Some(t) => t(true, station)
        None => ()
      }
      (self.d.disk.write)(
        turn_file(self.d.data),
        stringify(
          jo([
            ("ws", js(ws)),
            ("how", js(how)),
            ("station", js(station)),
            ("by", by_j(by)),
          ]),
        ),
      )
      let r = try Ok(f()) catch { e => Err(e) }
      for id in self.order {
        match self.modules[id].left {
          Some(left) =>
            left([]) catch {
              e =>
                self.d.say.log(
                  "warn",
                  "what is lent not looked at again",
                  jo([("error", js(message_of(e)))]),
                )
            }
          None => ()
        }
      }
      match r {
        Ok(v) => v
        Err(e) => raise e
      }
    }) catch { e => Err(e) }
    let head = [
      ("at", jn(self.now())),
      ("by", by_j(by)),
      ("how", js(how)),
      ("station", js(station)),
    ]
    match self.stopping {
      Some(s) => head.push(("stoppedBy", s))
      None => ()
    }
    match r {
      Ok(o) => self.keep_last(ws, spread(jo(head), o))
      Err(e) =>
        self.keep_last(
          ws,
          spread(
            jo(head),
            jo([
              ("done", ja([])),
              ("refused", ja([])),
              ("stopped", ja([])),
              ("resumed", ja([])),
              (
                "failed",
                jo([
                  ("item", Null),
                  ("error", js(say_of(self.d.say, e, "the turn"))),
                ]),
              ),
            ]),
          ),
        )
    }
    (self.d.disk.remove)(turn_file(self.d.data)) catch {
      _ => ()
    }
    match self.d.turn {
      Some(t) => t(false, station)
      None => ()
    }
    match let_go.val {
      Some(g) => g()
      None => ()
    }
    self.asked -= 1
    self.stopping = None
    self.current = None
    self.current_item = None
    self.bringing = Set::new()
    self.held = None
    self.changed()
    self.turn_lock.release()
    match r {
      Ok(o) => ignore(out.succeed(o))
      Err(e) => ignore(out.fail(e))
    }
    match self.running.search_by(x => physical_equal(x, ran)) {
      Some(i) => ignore(self.running.remove(i))
      None => ()
    }
    ignore(ran.succeed(()))
  })
  out
}

///|
async fn Scheduler::keep_last(self : Scheduler, ws : String, last : J) -> Unit {
  self.last = set(self.last, ws, last)
  (self.d.disk.write)(last_file(self.d.data), stringify(self.last)) catch {
    e =>
      self.d.say.log(
        "warn",
        "the last move not kept",
        jo([("error", js(message_of(e)))]),
      )
  }
}

///|
/// What came of a turn, as the TypeScript's object grows (its keys in the order first set).
priv struct Outcome {
  mut j : J
}

///|
fn Outcome::new() -> Outcome {
  {
    j: jo([
      ("done", ja([])),
      ("refused", ja([])),
      ("stopped", ja([])),
      ("resumed", ja([])),
      ("failed", Null),
    ]),
  }
}

///|
fn Outcome::list(self : Outcome, k : String) -> Array[J] {
  arr(get(Some(self.j), k)).unwrap_or([])
}

///|
fn Outcome::push(self : Outcome, k : String, v : J) -> Unit {
  let l = self.list(k).copy()
  l.push(v)
  self.j = set(self.j, k, ja(l))
}

///|
fn Outcome::put(self : Outcome, k : String, v : Array[J]) -> Unit {
  self.j = set(self.j, k, ja(v))
}

///|
fn Outcome::has(self : Outcome, k : String) -> Bool {
  has_key(self.j, k)
}

///|
fn need_j(x : J) -> J {
  item_need(x).to_j()
}

///|
fn refused_j(item : J, why : String) -> J {
  jo([("item", item), ("why", js(why))])
}

///|
fn need_of_named(k : String) -> Need {
  let i = index_of(k, " ")
  { module: slice(k, 0, i), id: slice_from(k, i + 1) }
}

///|
fn select(all : Array[J], sel : Selection) -> Array[J] {
  if sel.all {
    return all.filter(x => sel.module is None || sel.module == Some(item_module(x)))
  }
  match sel.module {
    None => []
    Some(m) =>
      all.filter(x => item_module(x) == m &&
        (sel.item is None || sel.item == Some(item_id(x))))
  }
}

///|
/// Whether `xs` holds `x` itself (the TypeScript's `Set` of objects).
fn holds(by : Map[String, Array[J]], x : J) -> Bool {
  match by.get(item_named(x)) {
    Some(l) => l.iter().any(y => physical_equal(y, x))
    None => false
  }
}

///|
fn by_name(items : Array[J]) -> Map[String, Array[J]] {
  let m : Map[String, Array[J]] = {}
  for x in items {
    match m.get(item_named(x)) {
      Some(l) => l.push(x)
      None => m[item_named(x)] = [x]
    }
  }
  m
}

///|
/// `items` in the order their needs make (what an item needs before it; a need outside them as if there).
fn order(items : Array[J], find : (Need) -> J?) -> Array[J] {
  let out = []
  let seen : Set[String] = Set::new()
  let among = by_name(items)
  fn visit(x : J, path : Set[String]) -> Unit {
    let k = item_named(x)
    if seen.contains(k) || path.contains(k) {
      return
    }
    path.add(k)
    for n in item_needs(x) {
      match find(n) {
        Some(y) if holds(among, y) => visit(y, path)
        _ => ()
      }
    }
    seen.add(k)
    out.push(x)
  }

  for x in items {
    visit(x, Set::new())
  }
  out
}

///|
/// `items` in the order of their needs, those that stop others (`stops`) as late as they can.
fn late_order(items : Array[J], find : (Need) -> J?, stops : (J) -> Bool) -> Array[J] {
  let ordered = order(items, find)
  let inside : Set[String] = Set::from_array(ordered.map(item_named))
  let of = (n : Need) => match find(n) {
    Some(y) if inside.contains(item_named(y)) => Some(y)
    _ => None
  }
  let behind : Map[String, Bool] = {}
  fn needs_stopper(x : J, path : Set[String]) -> Bool {
    let k = item_named(x)
    match behind.get(k) {
      Some(b) => return b
      None => ()
    }
    if path.contains(k) {
      return false
    }
    path.add(k)
    let r = item_needs(x).iter().any(n => match of(n) {
      Some(y) => stops(y) || needs_stopper(y, path)
      None => false
    })
    behind[k] = r
    r
  }

  let out = []
  let done : Set[String] = Set::new()
  let busy : Set[String] = Set::new()
  let needing = Items::new(ordered)
  letrec emit = fn(x : J) -> Unit {
    let k = item_named(x)
    if done.contains(k) || busy.contains(k) {
      return
    }
    busy.add(k)
    for n in item_needs(x) {
      match of(n) {
        Some(y) => if stops(y) { emit_stopper(y) } else { emit(y) }
        None => ()
      }
    }
    busy.remove(k)
    if done.contains(k) {
      return
    }
    done.add(k)
    out.push(x)
  }
  and emit_stopper = fn(s : J) -> Unit {
    if done.contains(item_named(s)) {
      return
    }
    emit(s)
    for d in needing.needing(item_need(s)) {
      emit(d)
    }
  }

  for x in ordered {
    if !stops(x) && !needs_stopper(x, Set::new()) {
      emit(x)
    }
  }
  for x in ordered {
    if stops(x) {
      emit_stopper(x)
    }
  }
  for x in ordered {
    emit(x)
  }
  out
}

///|
/// The items on a chain of items that need each other round, each with the chain it is on (Tarjan's).
fn item_cycles(items : Array[J]) -> Map[String, Array[J]] {
  let by : Map[String, J] = {}
  for x in items {
    by[item_named(x)] = x
  }
  let index : Map[String, Int] = {}
  let low : Map[String, Int] = {}
  let on : Set[String] = Set::new()
  let stack : Array[J] = []
  let out : Map[String, Array[J]] = {}
  let next = Ref(0)
  fn visit(x : J) -> Unit {
    let k = item_named(x)
    index[k] = next.val
    low[k] = next.val
    next.val += 1
    stack.push(x)
    on.add(k)
    for n in item_needs(x) {
      let y = match by.get(n.named()) {
        Some(y) => y
        None => continue
      }
      let j = item_named(y)
      if !index.contains(j) {
        visit(y)
        low[k] = if low[k] < low[j] { low[k] } else { low[j] }
      } else if on.contains(j) {
        low[k] = if low[k] < index[j] { low[k] } else { index[j] }
      }
    }
    if low[k] != index[k] {
      return
    }
    let part = []
    while true {
      let y = stack.pop().unwrap()
      on.remove(item_named(y))
      part.push(y)
      if item_named(y) == k {
        break
      }
    }
    let self_ = part.length() == 1 && item_needs(x).iter().any(n => n.named() == k)
    if part.length() < 2 && !self_ {
      return
    }
    let names : Set[String] = Set::from_array(part.map(item_named))
    let chain = cycle_through(x, names, by)
    for y in part {
      out[item_named(y)] = chain
    }
  }

  for x in items {
    if !index.contains(item_named(x)) {
      visit(x)
    }
  }
  out
}

///|
fn cycle_through(start : J, part : Set[String], by : Map[String, J]) -> Array[J] {
  let from : Map[String, J?] = {}
  from[item_named(start)] = None
  let queue = [start]
  let mut i = 0
  while i < queue.length() {
    let x = queue[i]
    i += 1
    for n in item_needs(x) {
      let y = match by.get(n.named()) {
        Some(y) if part.contains(item_named(y)) => y
        _ => continue
      }
      if item_named(y) == item_named(start) {
        let path = []
        let mut z : J? = Some(x)
        while z is Some(zz) {
          path.insert(0, zz)
          z = from.get(item_named(zz)).unwrap_or(None)
        }
        path.push(start)
        return path
      }
      if from.contains(item_named(y)) {
        continue
      }
      from[item_named(y)] = Some(x)
      queue.push(y)
    }
  }
  [start, start]
}

///|
fn Scheduler::progress_of(self : Scheduler, p : J) -> (J) -> Unit {
  let n = item_need(p)
  pr => match self.d.progress {
    Some(f) => f(n, pr)
    None => ()
  }
}

///|
async fn Scheduler::usable_here(self : Scheduler, x : J) -> Bool {
  match self.modules[item_module(x)].usable_here {
    Some(u) => u(x)
    None => false
  }
}

///|
async fn Scheduler::usable_there(self : Scheduler, x : J) -> Bool {
  match self.modules[item_module(x)].usable_there {
    Some(u) => u(x)
    None => false
  }
}

///|
async fn Scheduler::move_turn(self : Scheduler, ws : String, to : String, sel : Selection) -> J {
  let out = Outcome::new()
  let plan = self.plan(ws, to)
  if sel.all {
    match self.d.room_for_all {
      Some(f) =>
        match f(ws, to, plan) {
          Some(why) if why != "" => raise Said(why)
          _ => ()
        }
      None => ()
    }
  }
  self.hold_plan(ws, to, plan)
  let all = arr(get(Some(plan), "items")).unwrap_or([])
  let index = Items::new(all)
  let find = (n : Need) => index.find(n)
  let chosen = select(all, sel)
  if chosen.length() == 0 {
    raise Said(match sel.item {
      Some(i) =>
        self.say("noItem", [
          ("item", called(self.d.say, sel.module.unwrap_or(""), i)),
        ])
      None => self.say("nothing", [])
    })
  }
  let wanted : Map[String, J] = {}
  let taking : Set[String] = Set::new()
  let lending : Map[String, (J, Array[Need])] = {}
  let chosen_names : Set[String] = Set::from_array(chosen.map(item_named))
  let refused_why : Map[String, String] = {}
  // (why need `x` cannot be had there: its own `cannot`, or a need of its own that cannot; `again`: of this turn)
  async fn cannot_of(x : J, seen : Set[String]) -> (String, Bool)? {
    if state_name(x) == "there" || self.usable_there(x) {
      return None
    }
    match item_cannot(x) {
      Some(c) => return Some((c, item_again(x)))
      None => ()
    }
    if seen.contains(item_named(x)) {
      return None
    }
    seen.add(item_named(x))
    for n in item_needs(x) {
      match find(n) {
        Some(y) =>
          match cannot_of(y, seen) {
            Some((why, again)) =>
              return Some((self.need_cannot(y, why), again))
            None => ()
          }
        None => ()
      }
    }
    None
  }

  async fn cannot_go(p : J) -> (J, String, Bool)? {
    for n in item_needs(p) {
      match find(n) {
        Some(x) =>
          match cannot_of(x, Set::new()) {
            Some((why, again)) => return Some((x, why, again))
            None => ()
          }
        None => ()
      }
    }
    None
  }

  async fn would_stop_others(x : J) -> Array[J] {
    if self.usable_here(x) {
      return []
    }
    index
    .needing(item_need(x))
    .filter(y => state_name(y) != "there" &&
      !chosen_names.contains(item_named(y)) &&
      self.stoppable(item_module(y)))
  }

  async fn take(p : J) -> Unit {
    let k = item_named(p)
    if wanted.contains(k) || taking.contains(k) {
      return
    }
    taking.add(k)
    let blocked = if item_cannot(p) is None { cannot_go(p) } else { None }
    match blocked {
      Some((x, why, again)) if again || !sel.arrive_stopped => {
        refused_why[k] = self.need_cannot(x, why) +
          (if again { "" } else { self.say("orArrive", []) })
        return
      }
      _ => ()
    }
    if sel.with_needs || sel.all {
      for n in item_needs(p) {
        let x = match find(n) {
          Some(x) => x
          None => continue
        }
        if state_name(x) == "there" || self.usable_there(x) {
          continue
        }
        let m = self.modules[item_module(x)]
        let can_lend = match m.can_lend {
          Some(c) => c(x)
          None => false
        }
        if can_lend {
          match lending.get(item_named(x)) {
            Some((_, for_)) => for_.push(item_need(p))
            None => lending[item_named(x)] = (x, [item_need(p)])
          }
          continue
        }
        let others = if sel.all ||
          item_cannot(p) is Some(_) ||
          item_cannot(x) is Some(_) {
          []
        } else {
          would_stop_others(x)
        }
        if others.length() > 0 {
          let some = others[0:if others.length() > 3 { 3 } else { others.length() }]
            .iter()
            .map(y => self.called(y))
            .collect()
            .join("、")
          let more = if others.length() > 3 {
            self.say("more", [("n", (others.length() - 3).to_string())])
          } else {
            ""
          }
          refused_why[k] = self.say("wouldStop", [
            ("need", self.called(x)),
            ("some", "\{some}\{more}"),
          ])
          refused_why[item_named(x)] = self.say("wouldStopIt", [
            ("some", "\{some}\{more}"),
          ])
          continue
        }
        take(x)
      }
    }
    wanted[k] = p
  }

  let not_ready : Map[String, String] = {}
  for p in chosen {
    match self.modules[item_module(p)].ready {
      Some(ready) =>
        match ready(p, to) {
          Some(why) => not_ready[item_named(p)] = why
          None => ()
        }
      None => ()
    }
  }
  for p in chosen {
    match not_ready.get(item_named(p)) {
      Some(why) => out.push("refused", refused_j(need_j(p), why))
      None => take(p)
    }
  }
  for k, why in refused_why {
    match index.find(need_of_named(k)) {
      Some(x) => out.push("refused", refused_j(need_j(x), why))
      None => ()
    }
  }
  let there_now : Set[String] = Set::from_array(
    all.filter(x => state_name(x) == "there").map(item_named),
  )
  let wanted_list = wanted.values().collect()
  let going = if sel.all || sel.with_needs {
    let stops_others : Set[String] = Set::new()
    for p in wanted_list {
      if !self.usable_here(p) &&
        index
        .needing(item_need(p))
        .iter()
        .any(x => !there_now.contains(item_named(x)) &&
          self.stoppable(item_module(x))) {
        stops_others.add(item_named(p))
      }
    }
    late_order(wanted_list, find, x => stops_others.contains(item_named(x)))
  } else {
    order(wanted_list, find)
  }
  let mut unsaved = false
  let failed_here : Map[String, String] = {}
  let fail = (p : J, error : String) => {
    let f = jo([("item", need_j(p)), ("error", js(error))])
    out.push("failures", f)
    if get(Some(out.j), "failed") is Some(Null) {
      out.j = set(out.j, "failed", f)
    }
    failed_here[item_named(p)] = error
  }
  let lent_now : Set[String] = Set::new()
  let host_after : Array[J] = []
  for p in going {
    if self.stopping is Some(_) {
      break
    }
    if there_now.contains(item_named(p)) || refused_why.contains(item_named(p)) {
      continue
    }
    match item_cannot(p) {
      Some(c) => {
        out.push("refused", refused_j(p, c))
        continue
      }
      None => ()
    }
    if lending.contains(item_named(p)) {
      host_after.push(p)
      continue
    }
    for n in item_needs(p) {
      let x = match find(n) {
        Some(x) => x
        None => continue
      }
      if lending.contains(n.named()) || there_now.contains(n.named()) {
        continue
      }
      let m = self.modules[item_module(x)]
      match m.lent_for {
        Some(lent_for) => {
          let lent_to = text(get(Some((m.state)(x)), "lentTo"))
          if lent_to != Some(to) {
            continue
          }
          lent_for(x, to, [item_need(p)]) catch {
            e =>
              self.d.say.log(
                "warn",
                "an item not kept as one a lent login is lent for",
                jo([
                  ("item", js(item_named(p))),
                  ("lent", js(item_named(x))),
                  ("error", js(message_of(e))),
                ]),
              )
          }
        }
        None => continue
      }
    }
    for n in item_needs(p) {
      let (lx, lfor) = match lending.get(n.named()) {
        Some(l) => l
        None => continue
      }
      if lent_now.contains(n.named()) || failed_here.contains(n.named()) {
        continue
      }
      self.current = Some(item_need(lx))
      self.current_item = Some(lx)
      let lend = self.modules[item_module(lx)].lend.unwrap()
      match (try Ok(lend(lx, to, lfor)) catch { e => Err(e) }) {
        Ok(_) => {
          lent_now.add(n.named())
          out.push("lent", need_j(lx))
          self.changed()
        }
        Err(e) => fail(lx, say_of(self.d.say, e, item_named(lx)))
      }
    }
    let mut waits : Need? = None
    for n in item_needs(p) {
      if there_now.contains(n.named()) {
        continue
      }
      match find(n) {
        Some(x) => if !self.usable_there(x) { waits = Some(n); break }
        None => ()
      }
    }
    match waits {
      Some(w) =>
        match failed_here.get(w.named()) {
          Some(why) => {
            out.push(
              "refused",
              refused_j(
                p,
                self.say("waitsFailed", [
                  ("need", self.called(find(w).unwrap())),
                  ("why", why),
                ]),
              ),
            )
            continue
          }
          None =>
            if !sel.arrive_stopped {
              out.push(
                "refused",
                refused_j(
                  p,
                  self.say("needsFirst", [("need", self.called(find(w).unwrap()))]),
                ),
              )
              continue
            }
        }
      None => ()
    }
    let m = self.modules[item_module(p)]
    let stops = if self.usable_here(p) {
      []
    } else {
      index
      .needing(item_need(p))
      .filter(x => !there_now.contains(item_named(x)) &&
        !self.stopped.has(item_need(x)) &&
        self.stoppable(item_module(x)))
    }
    self.current = Some(item_need(p))
    self.current_item = Some(p)
    for x in stops {
      let waits_for : Waits = {
        module: item_module(p),
        id: item_id(p),
        label: Some(item_label(p)),
        at: Some(to),
      }
      self.stopped.add(Stopped::new(item_need(x), waits_for, ws))
      let stop = self.modules[item_module(x)].stop.unwrap()
      stop(x, waits_for) catch {
        e => {
          ignore(self.stopped.remove(item_need(x)))
          raise e
        }
      }
    }
    if stops.length() > 0 || unsaved {
      self.stopped.written()
      unsaved = false
    }
    let stopped_for = waits.map(w => {
      module: w.module,
      id: w.id,
      label: Some(item_label(find(w).unwrap())),
      at: None,
    })
    match (try Ok((m.move)(p, to, self.progress_of(p), stopped_for)) catch { e => Err(e) }) {
      Ok(_) => ()
      Err(e) => {
        fail(p, say_of(self.d.say, e, item_named(p)))
        let back = stops
          .filter_map(x => self.stopped.get(item_need(x)))
          .filter(s => s.waits_for.need() == item_need(p))
        self.let_go(back, true)
        unsaved = false
        continue
      }
    }
    match self.d.tell_arrived {
      Some(tell) =>
        tell(to, item_need(p)) catch {
          e =>
            self.d.say.log(
              "warn",
              "the other station not told what came",
              jo([("item", js(item_named(p))), ("error", js(message_of(e)))]),
            )
        }
      None => ()
    }
    there_now.add(item_named(p))
    out.push("done", need_j(p))
    self.ended(item_need(p), 1)
    for x in stops {
      out.push(
        "stopped",
        jo([("item", need_j(x)), ("waitsFor", need_j(p))]),
      )
    }
    if self.stopped.remove(item_need(p)) is Some(_) {
      unsaved = true
    }
    self.changed()
  }
  for p in host_after {
    if self.stopping is Some(_) {
      break
    }
    self.current = Some(item_need(p))
    self.current_item = Some(p)
    match (try Ok((self.modules[item_module(p)].move)(p, to, self.progress_of(p), None)) catch { e => Err(e) }) {
      Ok(_) => ()
      Err(e) => {
        fail(p, say_of(self.d.say, e, item_named(p)))
        continue
      }
    }
    there_now.add(item_named(p))
    out.push("done", need_j(p))
    self.ended(item_need(p), 1)
    self.changed()
  }
  let not_gone = out
    .list("failures")
    .map(f => need_of(get(Some(f), "item").unwrap_or(jo([]))))
    .filter(x => !lending.contains(x.named()))
  if not_gone.length() > 0 {
    for id in self.order {
      match self.modules[id].left {
        Some(left) =>
          left(not_gone) catch {
            e =>
              self.d.say.log(
                "warn",
                "what was lent for items that did not go not taken back",
                jo([("error", js(message_of(e)))]),
              )
          }
        None => ()
      }
    }
  }
  if out.has("lent") {
    let kept = []
    for n in out.list("lent") {
      match find(need_of(n)) {
        Some(x) => {
          let st = (self.modules[item_module(x)].state)(x)
          if get(Some(st), "lentTo") is Some(_) {
            kept.push(n)
          }
        }
        None => ()
      }
    }
    if kept.length() == 0 {
      out.j = del(out.j, "lent")
    } else {
      out.put("lent", kept)
    }
  }
  {
    let done_now : Set[String] = Set::from_array(
      out.list("done").map(d => need_of(d).named()),
    )
    let done_list = out.list("done").copy()
    done_list.rev_in_place()
    for xd in done_list {
      let x = need_of(xd)
      let p = match find(x) {
        Some(p) => p
        None => continue
      }
      if chosen_names.contains(x.named()) {
        continue
      }
      let for_whom = index
        .needing(x)
        .filter(y => wanted.contains(item_named(y)))
      if for_whom.length() == 0 ||
        for_whom.iter().any(y => done_now.contains(item_named(y))) {
        continue
      }
      match (try Ok((self.modules[item_module(p)].back)(p, to, None)) catch { e => Err(e) }) {
        Ok(_) => ()
        Err(e) => {
          fail(
            p,
            self.say("notBroughtBack", [
              ("for", for_whom.map(y => self.called(y)).join("、")),
              ("what", self.called(p)),
              ("why", say_of(self.d.say, e, item_named(p))),
            ]),
          )
          continue
        }
      }
      out.put("done", out.list("done").filter(d => need_of(d) != x))
      self.ended(x, -1)
      done_now.remove(x.named())
      out.push("returned", x.to_j())
      let waited = self.stopped.waiting_for(x)
      if waited.length() > 0 {
        for s in waited {
          out.push("resumed", s.item.to_j())
        }
        self.let_go(waited, true)
        out.put(
          "stopped",
          out
          .list("stopped")
          .filter(s => need_of(get(Some(s), "waitsFor").unwrap_or(jo([]))) != x),
        )
      }
    }
  }
  match sel.follow {
    Some(follow) if out.list("done").length() > 0 => {
      let after = self.plan(ws, to)
      let after_items = arr(get(Some(after), "items")).unwrap_or([])
      let there : Set[String] = Set::from_array(
        after_items.filter(x => state_name(x) == "there").map(item_named),
      )
      let done : Set[String] = Set::from_array(
        out.list("done").map(d => need_of(d).named()),
      )
      let after_index = Items::new(after_items)
      let following = after_items.filter(x => follow.contains(item_module(x)) &&
        state_name(x) != "there" &&
        item_cannot(x) is None &&
        item_needs(x).length() > 0 &&
        item_needs(x).iter().all(n => there.contains(n.named())) &&
        item_needs(x).iter().any(n => done.contains(n.named())))
      for p in order(following, n => after_index.find(n)) {
        match (try Ok((self.modules[item_module(p)].move)(p, to, self.progress_of(p), None)) catch { e => Err(e) }) {
          Ok(_) => {
            out.push("done", need_j(p))
            self.ended(item_need(p), 1)
            if self.stopped.remove(item_need(p)) is Some(_) {
              unsaved = true
            }
          }
          Err(e) => fail(p, say_of(self.d.say, e, item_named(p)))
        }
      }
    }
    _ => ()
  }
  if unsaved {
    self.stopped.written()
  }
  self.changed()
  out.j
}

///|
fn Scheduler::need_cannot(self : Scheduler, x : J, why : String) -> String {
  self.say("needCannot", [("need", self.called(x)), ("why", why)])
}

///|
async fn Scheduler::back_turn(self : Scheduler, ws : String, from : String, sel : Selection) -> J {
  let out = Outcome::new()
  let plan = self.plan(ws, from)
  self.hold_plan(ws, from, plan)
  let all = arr(get(Some(plan), "items")).unwrap_or([])
  let index = Items::new(all)
  let find = (n : Need) => index.find(n)
  let chosen = select(all, sel).filter(x => state_name(x) == "there")
  if chosen.length() == 0 {
    raise Said(match sel.item {
      Some(i) =>
        self.say("notThere", [
          ("item", called(self.d.say, sel.module.unwrap_or(""), i)),
        ])
      None => self.say("nothingThere", [])
    })
  }
  let backing : Set[String] = Set::from_array(chosen.map(item_named))
  match sel.follow {
    Some(follow) =>
      for p in chosen {
        for x in index.needing(item_need(p)) {
          if follow.contains(item_module(x)) && state_name(x) == "there" {
            backing.add(item_named(x))
          }
        }
      }
    None => ()
  }
  if sel.all || sel.with_needs {
    let queue = chosen.copy()
    let mut i = 0
    while i < queue.length() {
      for x in index.needing(item_need(queue[i])) {
        if state_name(x) == "there" && !backing.contains(item_named(x)) {
          backing.add(item_named(x))
          queue.push(x)
        }
      }
      i += 1
    }
  }
  self.bringing = backing
  let still_there : Set[String] = Set::from_array(
    all.filter(x => state_name(x) == "there").map(item_named),
  )
  let failed_there : Map[String, String] = {}
  let ordered = order(all.filter(x => backing.contains(item_named(x))), find)
  ordered.rev_in_place()
  for p in ordered {
    if self.stopping is Some(_) {
      break
    }
    self.current = Some(item_need(p))
    self.current_item = Some(p)
    match index.needing(item_need(p)).search_by(x => still_there.contains(item_named(x))) {
      Some(i) => {
        let dependent = index.needing(item_need(p))[i]
        let why = match failed_there.get(item_named(dependent)) {
          Some(failed) =>
            self.say("backNeedsFailed", [
              ("item", self.called(dependent)),
              ("why", failed),
            ])
          None => self.say("backNeeds", [("item", self.called(dependent))])
        }
        out.push("refused", refused_j(p, why))
        continue
      }
      None => ()
    }
    let mut waits : J? = None
    for n in item_needs(p) {
      match find(n) {
        Some(x) =>
          if still_there.contains(item_named(x)) && !self.usable_here(x) {
            waits = Some(x)
            break
          }
        None => ()
      }
    }
    let stopped_for = waits.map(w => {
      module: item_module(w),
      id: item_id(w),
      label: Some(item_label(w)),
      at: None,
    })
    match (try Ok((self.modules[item_module(p)].back)(p, from, stopped_for)) catch { e => Err(e) }) {
      Ok(_) => ()
      Err(e) => {
        let error = say_of(self.d.say, e, item_named(p))
        let f = jo([("item", need_j(p)), ("error", js(error))])
        out.push("failures", f)
        if get(Some(out.j), "failed") is Some(Null) {
          out.j = set(out.j, "failed", f)
        }
        failed_there[item_named(p)] = error
        continue
      }
    }
    match waits {
      Some(w) => {
        self.note_stopped(
          item_need(p),
          {
            module: item_module(w),
            id: item_id(w),
            label: Some(item_label(w)),
            at: Some(from),
          },
          ws,
          hold=false,
        )
        out.push(
          "stopped",
          jo([("item", need_j(p)), ("waitsFor", need_j(w))]),
        )
      }
      None => ()
    }
    still_there.remove(item_named(p))
    out.push("done", need_j(p))
    self.ended(item_need(p), -1)
    for id in self.order {
      match self.modules[id].left {
        Some(left) =>
          left([item_need(p)]) catch {
            e =>
              self.d.say.log(
                "warn",
                "what was lent for an item back here not taken back",
                jo([("error", js(message_of(e)))]),
              )
          }
        None => ()
      }
    }
    let waited = self.stopped.waiting_for(item_need(p))
    if waited.length() > 0 {
      for s in waited {
        out.push("resumed", s.item.to_j())
      }
      self.let_go(waited, true)
    }
    self.changed()
  }
  out.j
}

///|
/// An item that arrived here stopped, waiting for `waits_for`: kept stopped here, held by its module (`hold`: false,
/// it held itself as it arrived).
pub async fn Scheduler::note_stopped(
  self : Scheduler,
  item : Need,
  waits_for : Waits,
  ws : String,
  hold? : Bool = true,
) -> Unit {
  if hold {
    match self.modules.get(item.module) {
      Some({ stop: Some(stop), .. }) =>
        stop(bare_item(item.module, item.id, [waits_for]), waits_for)
      _ => ()
    }
  }
  if self.stopped.has(item) {
    ignore(self.stopped.remove(item))
  }
  self.stopped.add(Stopped::new(item, waits_for, ws))
  self.stopped.written()
  self.changed()
}

///|
/// Items `gone` went from here: no longer stopped here, nothing let go or resumed.
pub async fn Scheduler::forget(self : Scheduler, gone : Array[Need]) -> Unit {
  let mut changed = false
  for item in gone {
    if self.stopped.remove(item) is Some(_) {
      changed = true
    }
  }
  if !changed {
    return
  }
  self.stopped.written()
  self.changed()
}

///|
/// `item` is here now (another station moved it here): what waited here for it goes on.
pub async fn Scheduler::arrived(self : Scheduler, item : Need) -> Array[Need] {
  let waited = self.stopped.waiting_for(item)
  let going = waited.map(s => s.item)
  self.let_go(waited, true)
  self.changed()
  going
}

///|
/// The stopped items `gone` let go (`resume`: told to go on here; else they moved).
async fn Scheduler::let_go(self : Scheduler, gone : Array[Stopped], resume : Bool) -> Unit {
  if gone.length() == 0 {
    return
  }
  for s in gone {
    ignore(self.stopped.remove(s.item))
  }
  self.stopped.written()
  if !resume {
    return
  }
  for s in gone {
    match self.modules.get(s.item.module) {
      Some({ resume: Some(resume), .. }) =>
        resume(bare_item(s.item.module, s.item.id, [s.waits_for])) catch {
          e =>
            self.d.say.log(
              "warn",
              "an item not let go",
              jo([("item", js(s.item.named())), ("error", js(message_of(e)))]),
            )
        }
      _ => ()
    }
  }
}

///|
/// What was changed of the stopped items written (a test's).
pub async fn Scheduler::written(self : Scheduler) -> Unit {
  self.stopped.written()
}
