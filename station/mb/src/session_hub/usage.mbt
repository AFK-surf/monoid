// What the agents spent, counted and kept (station/src/usage/counter.ts, module.ts, minute-reader.ts): when the usage
// counter's program reads the transcripts (at its start, shortly after a turn ends, shortly after a session at work
// wrote more, and every SAFETY_MS for what no turn's end told; reads never overlap), each session's usage as its summary
// says it kept from what was recorded (`keepUsage`), and the usage checker asked whether the statistics kept apart are
// complete. The reading itself is the program's (mb/src/usagecount, `--builder usage-counter`; mb/src/usage,
// `--builder usage-check`): the world's here (`usage.read`, `usageCheck.*`).

///|
/// counter.ts `SETTLE_MS`: how long after a turn ends, or a session at work wrote more, its transcript is read.
pub let settle_ms : Double = 2_000.0

///|
/// counter.ts `SAFETY_MS`: how often everything that ran is read anyway.
pub let safety_ms : Double = 600_000.0

///|
/// counter.ts `TIMED_BACK_MS`: how far back the calls read before their time was kept are timed as it starts.
pub let timed_back_ms : Double = 691_200_000.0

///|
/// module.ts `keepUsage`: a session's usage as its summary says it, as recorded now (none before a call). `quiet`: not
/// told as a change of the session.
pub fn Hub::keep_usage(self : Hub, key : String, quiet? : Bool = false) -> Unit raise {
  match self.usage_now(key) {
    Some(u) => self.store.set_session_usage(key, u, quiet)
    None => ()
  }
}

///|
/// module.ts `keepCounted`: what the store told of usage recorded (not of the statistics alone) or a conversation gone
/// on in another: each session's kept, and the live view told the counter counted.
pub fn Hub::counted(self : Hub, change : Json) -> Unit {
  let sessions = match str_of(change, "type") {
    Some("usage") if !is_true(change, "statisticsOnly") => items(field(change, "sessions")).map(js_string)
    Some("conversation") => [str_of(change, "key").unwrap_or("")]
    _ => return
  }
  for key in sessions {
    self.keep_usage(key) catch {
      _ => ()
    }
  }
  (self.world.tell)("live.usageCounted", Json::null())
}

///|
/// counter.ts `UsageCounter`: when the transcripts are read.
pub struct UsageCounter {
  hub : Hub
  settle : Double
  safety : Double
  /// When the last read started; 0 before the first.
  mut last : Double
  mut first : Bool
  /// Sessions that changed since the loop last looked, and when each one's latest turn had ended when it last did.
  changed : Array[String]
  ended : Map[String, Double]
  mut started_at : Double
  /// A wake waiting (the queue of one).
  mut wake : Bool
  /// Sessions at work whose transcripts grew, read alone though no turn ended.
  asked : Array[String]
  /// Where the loop is: 0 waiting (on a wake or its due), 1 settling, 2 reading, -1 stopped.
  mut state : Int
  mut due : Double
  mut timer : Int?
}

///|
pub fn UsageCounter::new(hub : Hub, settle? : Double = settle_ms, safety? : Double = safety_ms) -> UsageCounter {
  {
    hub,
    settle,
    safety,
    last: 0.0,
    first: false,
    changed: [],
    ended: {},
    started_at: 0.0,
    wake: false,
    asked: [],
    state: -1,
    due: 0.0,
    timer: None,
  }
}

///|
/// What the store told: a session deleted forgotten; one changed noted, and the loop woken.
pub fn UsageCounter::told(self : UsageCounter, change : Json) -> Unit {
  if self.state < 0 {
    return
  }
  let key = str_of(change, "key").unwrap_or("")
  match str_of(change, "type") {
    Some("sessionRemoved") => {
      self.ended.remove(key)
      remove_all(self.changed, key)
      remove_all(self.asked, key)
    }
    Some("session") => {
      if !self.changed.contains(key) {
        self.changed.push(key)
      }
      self.woken()
    }
    _ => ()
  }
}

///|
fn remove_all(xs : Array[String], x : String) -> Unit {
  while xs.search(x) is Some(i) {
    ignore(xs.remove(i))
  }
}

///|
/// A wake: taken at once where the loop waits on one, else kept (one at most) for when it does.
fn UsageCounter::woken(self : UsageCounter) -> Unit {
  if self.state == 0 {
    match self.timer {
      Some(t) => self.hub.cancel(t)
      None => ()
    }
    self.timer = None
    self.settling()
  } else {
    self.wake = true
  }
}

///|
/// Starts reading: at once, then as told.
pub async fn UsageCounter::start(self : UsageCounter) -> Unit {
  if self.state >= 0 {
    return
  }
  self.started_at = self.hub.now()
  self.state = 2
  // (as it starts: what was read before calls were timed, of the sessions that ran the last TIMED_BACK_MS, timed too)
  let from = self.hub.now() - timed_back_ms
  ignore(self.read(None, time_from=from))
  let active = self.hub.store.usage_active_sessions(Json::number(from)) catch { _ => [] }
  ignore(self.read(Some(active.map(js_string)), time_from=from))
  self.due = self.hub.now() + self.safety
  self.waiting()
}

///|
fn UsageCounter::waiting(self : UsageCounter) -> Unit {
  if self.state < 0 {
    return
  }
  self.state = 0
  if self.wake {
    self.wake = false
    self.settling()
    return
  }
  let wait = self.due - self.hub.now()
  self.timer = Some(self.hub.after(if wait > 1.0 { wait } else { 1.0 }, () => {
    self.timer = None
    self.asked.clear()
    self.state = 2
    self.hub.later(async fn() {
      ignore(self.read(None))
      self.due = self.hub.now() + self.safety
      self.waiting()
    })
  }))
}

///|
fn UsageCounter::settling(self : UsageCounter) -> Unit {
  self.state = 1
  self.timer = Some(self.hub.after(self.settle, () => {
    self.timer = None
    self.wake = false
    let ended = self.turn_ended()
    if !ended && self.hub.now() < self.due {
      if self.asked.length() > 0 {
        let only = self.asked.copy()
        self.asked.clear()
        self.state = 2
        self.hub.later(async fn() {
          ignore(self.read(Some(only)))
          self.waiting()
        })
      } else {
        self.waiting()
      }
      return
    }
    self.asked.clear()
    self.state = 2
    self.hub.later(async fn() {
      ignore(self.read(None))
      self.due = self.hub.now() + self.safety
      self.waiting()
    })
  }))
}

///|
/// Whether a turn ended since the loop last looked, of the sessions that changed.
fn UsageCounter::turn_ended(self : UsageCounter) -> Bool {
  let mut ended = false
  for key in self.changed {
    let last = self.hub.store.last_turn(Json::string(key)) catch { _ => Json::null() }
    match num_of(last, "endedAt") {
      Some(at) =>
        if at > self.ended.get(key).unwrap_or(self.started_at) {
          self.ended[key] = at
          ended = true
        }
      None => ()
    }
  }
  self.changed.clear()
  ended
}

///|
/// `soon`: a session at work wrote more: read shortly, though no turn ended.
pub fn UsageCounter::soon(self : UsageCounter, key : String) -> Unit {
  if !self.asked.contains(key) {
    self.asked.push(key)
  }
  if self.state >= 0 {
    self.woken()
  }
}

///|
/// `readingAll`: whether everything is still being read for the first time.
pub fn UsageCounter::reading_all(self : UsageCounter) -> Bool {
  self.first || self.last == 0.0
}

///|
/// Stops reading.
pub fn UsageCounter::stop(self : UsageCounter) -> Unit {
  match self.timer {
    Some(t) => self.hub.cancel(t)
    None => ()
  }
  self.timer = None
  self.state = -1
  (self.hub.world.tell)("usage.close", Json::null())
}

///|
/// One read by the program: the transcripts of sessions that ran since the last sweep (`only`: of those alone). How many
/// calls were new; a failure is only told.
pub async fn UsageCounter::read(self : UsageCounter, only : Array[String]?, time_from? : Double) -> Double {
  let started = self.hub.now()
  let last = self.last
  if only is None {
    self.first = last == 0.0
  }
  let config = self.hub.config()
  let answer = (self.hub.world.ask)("usage.read", {
    "only": match only {
      None => Json::null()
      Some(o) => Json::array(o.map(Json::string))
    },
    "started": num(started),
    "last": num(last),
    "dataDir": field(config, "dataDir").unwrap_or(Json::null()),
    "homes": Json::array(items(field(config, "profiles")).map(p => field(p, "home").unwrap_or(Json::null()))),
    "timeFrom": match time_from {
      Some(t) => num(t)
      None => Json::null()
    },
  }) catch {
    _ => return 0.0
  }
  if only is None {
    self.last = started
    self.first = false
  }
  let sessions = items(field(answer, "sessions"))
  if sessions.length() > 0 {
    let from = match field(answer, "from") {
      None | Some(Null) => None
      f => f
    }
    self.hub.store.usage_changed(sessions, from, false)
  }
  num_of(answer, "added").unwrap_or(0.0)
}

///|
/// Runs `f` as work of the hub's own, after what set it going (a fiber of no sleep).
pub fn Hub::later(self : Hub, f : async () -> Unit) -> Unit {
  ignore(self)
  pending_work.push(f)
}

///|
/// The hub's work set going and not run yet (`later`), run by whoever runs the hub (the harness at each step's end).
pub let pending_work : Array[async () -> Unit] = []

///|
/// Runs what is due by now and the work set going, and what they set going, till none is left.
pub async fn Hub::settle(self : Hub) -> Unit {
  while true {
    self.run_due(self.now())
    if pending_work.length() == 0 {
      break
    }
    let f = pending_work.remove(0)
    f()
  }
}

// ── minute-reader.ts: the usage checker ──

///|
/// How long a checker with nothing asked of it is kept.
pub let check_idle_ms : Double = 60_000.0

///|
/// `MinuteReader`: whether the statistics kept apart from the usage itself are complete, asked of the checker program,
/// one with nothing asked of it let go after `check_idle_ms` and started again by the next ask.
pub struct UsageCheck {
  hub : Hub
  mut running : Bool
  mut next : Int
  mut closed : Bool
  mut complete : Bool
  /// What is asked and not answered: its request, and whether it was sent.
  waiting : Map[Int, (Json, Bool)]
  answered : Map[Int, @effect.Deferred[Unit]]
  mut idle : Int?
}

///|
pub fn UsageCheck::new(hub : Hub) -> UsageCheck {
  { hub, running: false, next: 0, closed: false, complete: false, waiting: {}, answered: {}, idle: None }
}

///|
fn UsageCheck::let_go(self : UsageCheck) -> Unit {
  match self.idle {
    Some(t) => self.hub.cancel(t)
    None => ()
  }
  self.idle = None
  if !self.running {
    return
  }
  self.running = false
  (self.hub.world.tell)("usageCheck.terminate", Json::null())
}

///|
/// `trimIdle`: let go at once if nothing is asked of it: 1, else 0.
pub fn UsageCheck::trim_idle(self : UsageCheck) -> Int {
  if self.closed || !self.running || self.waiting.length() > 0 {
    return 0
  }
  self.let_go()
  1
}

///|
fn UsageCheck::idle_later(self : UsageCheck) -> Unit {
  if self.closed || !self.running || self.waiting.length() > 0 || self.idle is Some(_) {
    return
  }
  self.idle = Some(self.hub.after(check_idle_ms, () => {
    self.idle = None
    if self.waiting.length() == 0 {
      self.let_go()
    }
  }))
}

///|
fn UsageCheck::start(self : UsageCheck) -> Unit {
  if self.closed || self.complete || self.running {
    return
  }
  self.running = true
  (self.hub.world.tell)("usageCheck.start", Json::null())
  self.send_waiting()
  self.idle_later()
}

///|
fn UsageCheck::send_waiting(self : UsageCheck) -> Unit {
  if !self.running {
    return
  }
  if self.waiting.length() > 0 {
    match self.idle {
      Some(t) => self.hub.cancel(t)
      None => ()
    }
    self.idle = None
  }
  let ids = []
  for id, _ in self.waiting {
    ids.push(id)
  }
  for id in ids {
    let (request, sent) = self.waiting.get(id).unwrap()
    if !sent {
      (self.hub.world.tell)("usageCheck.post", request)
      self.waiting[id] = (request, true)
    }
  }
}

///|
/// What the checker said: complete (every ask answered, the checker let go), or an ask answered (`error`: refused).
pub fn UsageCheck::heard(self : UsageCheck, answer : Json) -> Unit {
  if is_true(answer, "complete") {
    self.complete = true
    for _, d in self.answered {
      ignore(d.succeed(()))
    }
    self.answered.clear()
    self.waiting.clear()
    if self.running {
      self.running = false
      (self.hub.world.tell)("usageCheck.terminate", Json::null())
    }
    return
  }
  let id = match num_of(answer, "id") {
    Some(i) => i.to_int()
    None => return
  }
  match self.answered.get(id) {
    None => return
    Some(d) => {
      self.answered.remove(id)
      self.waiting.remove(id)
      match str_of(answer, "error") {
        Some(m) => ignore(d.fail(Refused(m)))
        None => ignore(d.succeed(()))
      }
    }
  }
  self.idle_later()
}

///|
/// The checker ended (`code`): what waited on it refused.
pub fn UsageCheck::exited(self : UsageCheck, code : Int, failure? : String) -> Unit {
  let current = self.running
  self.running = false
  if current && !self.complete && !self.closed {
    for _, d in self.answered {
      ignore(d.fail(Refused(failure.unwrap_or("the minute summary worker stopped (exit \{code})"))))
    }
    self.answered.clear()
    self.waiting.clear()
  }
}

///|
async fn UsageCheck::ask(self : UsageCheck, request : (Int) -> Json) -> Unit {
  if self.closed {
    raise Refused("station stopping")
  }
  self.next += 1
  let id = self.next
  let d : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.waiting[id] = (request(id), false)
  self.answered[id] = d
  self.start()
  self.send_waiting()
  d.wait()
}

///|
/// `readyRemote`: the remote tasks' statistics complete.
pub async fn UsageCheck::ready_remote(self : UsageCheck) -> Unit {
  if self.closed {
    raise Refused("station stopping")
  }
  if self.complete {
    return
  }
  self.ask(id => { "id": int(id), "remote": true })
}

///|
/// `readyChats`: the asking workspace's chat and card totals complete.
pub async fn UsageCheck::ready_chats(self : UsageCheck, viewer : Json) -> Unit {
  if self.closed {
    raise Refused("station stopping")
  }
  self.complete = false
  self.ask(id => { "id": int(id), "chats": viewer })
}

///|
pub fn UsageCheck::close(self : UsageCheck) -> Unit {
  self.closed = true
  match self.idle {
    Some(t) => self.hub.cancel(t)
    None => ()
  }
  self.idle = None
  for _, d in self.answered {
    ignore(d.fail(Refused("station stopping")))
  }
  self.answered.clear()
  self.waiting.clear()
  if self.running {
    (self.hub.world.tell)("usageCheck.terminate", Json::null())
  }
  self.running = false
}

// ── module.ts: the chats of moved sessions counted again, the old statistics retired ──

///|
/// `drainUsageChats`: the chats of sessions that moved between workspaces given their new workspace, a batch at a time
/// (the store's step, the world's), once the station before has gone and again each time sessions move; pages open told
/// once none waits.
pub struct UsageDrain {
  hub : Hub
  batch : Int
  mut stopped : Bool
  mut ready : Bool
  mut running : Bool
  mut again : Bool
}

///|
pub fn UsageDrain::new(hub : Hub, batch? : Int = 32) -> UsageDrain {
  let d = { hub, batch, stopped: false, ready: false, running: false, again: false }
  ignore(hub.store.on_session_workspace_change(() => d.wake()))
  d
}

///|
/// The station before has gone: it may drain from now on.
pub fn UsageDrain::begin(self : UsageDrain) -> Unit {
  self.ready = true
  self.wake()
}

///|
pub fn UsageDrain::wake(self : UsageDrain) -> Unit {
  if self.stopped || !self.ready {
    return
  }
  if self.running {
    self.again = true
    return
  }
  self.running = true
  self.hub.later(async fn() {
    self.run()
    self.running = false
  })
}

///|
async fn UsageDrain::run(self : UsageDrain) -> Unit {
  while true {
    self.again = false
    let mut moved = false
    while true {
      if self.stopped {
        return
      }
      let step = (self.hub.world.ask)("usage.drainStep", int(self.batch)) catch {
        _ => return
      }
      if num_of(step, "processed").unwrap_or(0.0) > 0.0 {
        moved = true
      }
      if is_true(step, "done") {
        break
      }
    }
    if moved {
      self.hub.store.usage_changed([], None, true)
    }
    if !self.again || self.stopped {
      break
    }
  }
}

///|
pub fn UsageDrain::stop(self : UsageDrain) -> Unit {
  self.stopped = true
}

///|
/// A pause on the hub's clock.
async fn Hub::pause(self : Hub, ms : Double) -> Unit {
  let d : @effect.Deferred[Unit] = @effect.Deferred::new()
  ignore(self.after(ms, () => ignore(d.succeed(()))))
  d.wait()
}

///|
/// `retireAfterPrevious`: once the station before has gone, the old statistics' writers stopped (the store's step, the
/// world's: tried again after 50 ms where another connection writes), then the program's retirement (`--builder
/// usage-retire`, a step at a time: freed, then the old calls taken in, newest first, with at most about a tenth of the
/// time going to them); pages open told once old days came in. Whether all of it is done.
pub async fn Hub::retire_after_previous(self : Hub) -> Bool {
  let mut stopped = false
  let result = try {
    while (self.world.ask)("usage.stopIndexes", Json::null()) != Json::boolean(true) {
      self.pause(50.0)
    }
    stopped = true
    if (self.world.ask)("usage.inMemory", Json::null()) == Json::boolean(true) {
      return true
    }
    while !is_true((self.world.ask)("usage.retireStep", { "drop": true }), "done") {

    }
    let mut filled = false
    while true {
      let step = (self.world.ask)("usage.retireStep", Json::object({}))
      if is_true(step, "done") {
        break
      }
      filled = true
      let took = num_of(step, "ms").unwrap_or(0.0)
      self.pause(if took * 9.0 > 200.0 { took * 9.0 } else { 200.0 })
    }
    if filled {
      self.store.usage_changed([], None, true)
    }
    true
  } catch {
    e => {
      (self.world.tell)("log", {
        "warn": Json::string(if stopped { "the old usage statistics could not be removed" } else { "the old usage statistics' writers could not be stopped" }),
        "error": Json::string(error_words(e)),
      })
      false
    }
  }
  result
}

///|
/// `retireUntilComplete`: tried again, its pause doubling to 30 s, till done.
pub async fn Hub::retire_usage(self : Hub) -> Unit {
  let mut retry = 250.0
  while !self.retire_after_previous() {
    self.pause(retry)
    retry = if retry * 2.0 < 30_000.0 { retry * 2.0 } else { 30_000.0 }
  }
}
