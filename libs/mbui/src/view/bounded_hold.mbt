// Local reads may hold a transition for a declared budget on the tree's timeline. A source that knows it is waiting
// for the network says ready here and lets the new view show its bones while the network answers.

///|
/// A wait at least this long without visible feedback is a silent hold.
pub let silent_hold_ms : Double = 150.0

///|
/// A wait at least this long even with visible feedback is a long hold.
pub let long_hold_ms : Double = 500.0

///|
pub struct HoldGate {
  priv made : SourceLoc
  priv always_acknowledged : Bool
  priv mut pending_ack : Bool
  priv once : Bool
  priv mut through : Bool
  priv holding : @signals.Signal[Bool]
  priv mut staged : Array[HoldCondition]
  priv mut sealed_in : View?
  priv mut active : HoldRun?
}

///|
priv struct HoldCondition {
  loc : SourceLoc
  mut ready : () -> Bool
}

///|
priv struct HoldRun {
  mut node : View
  mut awaiting_seal : Bool
  most : Double
  loc : SourceLoc
  check : () -> Bool
  still : () -> Bool
  give_up : () -> Unit
  go : () -> Unit
  acknowledged : Ref[Bool]
  mut conds : Array[HoldCondition]
  slots : Map[String, Array[HoldCondition]]
  mut first : SourceLoc?
  mut sample : (HoldLog, HoldSample)?
  mut unown : () -> Unit
  mut unwatch : () -> Unit
  mut untime : () -> Unit
}

///|
priv enum HoldCollection {
  Staged(HoldGate)
  Checking(HoldGate, HoldRun, Map[String, Int])
}

///|
// kept across runs: pushed and popped within each collection or read, checked and cleared by the Tester's reset
let hold_gates : Array[HoldCollection] = []

///|
/// A gate for one transition at a time. An acknowledged gate has feedback on every round. With once, calls to
/// go pass synchronously after this gate's first successful transition, including a deadline release.
#callsite(autofill(loc))
pub fn HoldGate::new(acknowledged? : Bool = false, once? : Bool = false, loc~ : SourceLoc) -> HoldGate {
  {
    made: loc,
    always_acknowledged: acknowledged,
    pending_ack: false,
    once,
    through: false,
    holding: @signals.signal(false),
    staged: [],
    sealed_in: None,
    active: None,
  }
}

///|
fn[T] collecting_hold(collection : HoldCollection, make : () -> T) -> T {
  let depth = hold_gates.length()
  hold_gates.push(collection)
  let result = make()
  if hold_gates.length() > depth {
    hold_gates.truncate(depth)
  }
  result
}

///|
/// Run `make` with this gate collecting readiness conditions for its next `go`.
pub fn HoldGate::collect(self : HoldGate, make : () -> Unit) -> Unit {
  // Nested collection for the same gate adds to this round. After a seal, a new collection needs a new owner.
  if self.sealed_in is Some(_) &&
    !hold_gates.iter().any(fn(entry) { entry is Staged(gate) && physical_equal(gate, self) }) {
    self.sealed_in = None
    self.staged = []
  }
  collecting_hold(Staged(self), make)
}

///|
/// Whether the current make or readiness check is collecting conditions.
pub fn hold_collecting() -> Bool {
  !hold_gates.is_empty()
}

///|
/// Register a local read for the innermost gate. A source that knows it is waiting remotely can say ready here so
/// the new view shows its bones. A reactive read can redeclare the same callsite and slot on each evaluation.
#callsite(autofill(loc))
pub fn hold_note(ready : () -> Bool, loc~ : SourceLoc) -> Unit {
  match hold_gates.last() {
    Some(Staged(gate)) if !gate.through => gate.staged.push({ loc, ready })
    Some(Checking(gate, run, seen)) => {
      let site = loc.to_string()
      let slot = seen.get(site).unwrap_or(0)
      seen[site] = slot + 1
      let conditions = run.slots.get_or_init(site, fn() { [] })
      match conditions.get(slot) {
        Some(known) => known.ready = ready
        None => {
          let condition : HoldCondition = { loc, ready }
          conditions.push(condition)
          run.conds.push(condition)
          if run.sample is Some((log, sample)) && run.first is Some(first) {
            let at = run.node.tree.logic_said()
            if at > sample.start {
              hold_log_push(
                log.waterfalls,
                "[ASYNC_WATERFALL] Hold at \{source_place(gate.made)} started another async read at \{source_place(loc)} " +
                "(\{at - sample.start}ms after \{source_place(first)}). " +
                "Fix: issue independent reads together up front before the first answer so they resolve in parallel.",
              )
            }
          }
        }
      }
    }
    _ => ()
  }
}

///|
/// Whether this gate is waiting. A tracked binding that reads it acknowledges the wait as visible.
pub fn HoldGate::is_pending(self : HoldGate) -> Bool {
  if @signals.active_sub() is Some(_) && self.active is Some(run) && run.sample is Some((_, sample)) {
    sample.acknowledged.val = true
  }
  self.holding.get()
}

///|
/// Say that a pending or optimistic UI gives feedback for the current transition, or the next one if idle.
pub fn HoldGate::acknowledge(self : HoldGate) -> Unit {
  match self.active {
    Some(run) => run.acknowledged.val = true
    None => self.pending_ack = true
  }
}

///|
fn HoldRun::new(
  node : View,
  most : Double,
  check : () -> Bool,
  still : () -> Bool,
  give_up : () -> Unit,
  go : () -> Unit,
  loc : SourceLoc,
) -> HoldRun {
  if !(most >= 0.0 && most < @double.infinity) {
    @halt.saying("HoldGate requires a finite, non-negative most at " + source_place(loc))
  }
  {
    node, most, check, still, give_up, go, loc,
    awaiting_seal: false,
    acknowledged: Ref(false),
    conds: [],
    slots: Map([]),
    first: None,
    sample: None,
    unown: fn() {  },
    unwatch: fn() {  },
    untime: fn() {  },
  }
}

///|
/// Complete collection. The gate belongs to `v` and starts any `go` already requested.
pub fn HoldGate::seal(self : HoldGate, v : View) -> Unit {
  self.sealed_in = Some(v)
  if self.active is Some(run) && run.awaiting_seal {
    run.awaiting_seal = false
    (run.unown)()
    run.node = v
    self.start_collected(run)
  }
}

///|
/// Let the transition go once the collected reads are ready or `most` milliseconds have elapsed. A request before
/// `seal` is kept by `v` until collection ends, when its budget can begin.
#callsite(autofill(loc))
pub fn HoldGate::go(
  self : HoldGate,
  v : View,
  most~ : Double,
  while_still? : () -> Bool = fn() { true },
  on_give_up? : () -> Unit = fn() {  },
  go : () -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  let run = HoldRun::new(v, most, fn() { true }, while_still, on_give_up, go, loc)
  guard self.install(run) else { return }
  if self.through {
    self.start(run)
    return
  }
  match self.sealed_in {
    Some(owner) => {
      run.node = owner
      self.start_collected(run)
    }
    None => {
      run.awaiting_seal = true
      self.own_run(run)
    }
  }
}

///|
fn HoldGate::start_collected(self : HoldGate, run : HoldRun) -> Unit {
  // Keep the sealed reads so an interrupted transition can go again without collecting them anew.
  run.conds = self.staged.copy()
  self.start(run)
}

///|
/// Run `check` and any conditions it collects as their signals change. Each newly reached read shares the budget
/// that started with the first unresolved check.
#callsite(autofill(loc))
pub fn HoldGate::open_when(
  self : HoldGate,
  v : View,
  most~ : Double,
  check : () -> Bool,
  while_still? : () -> Bool = fn() { true },
  on_give_up? : () -> Unit = fn() {  },
  go : () -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  let run = HoldRun::new(v, most, check, while_still, on_give_up, go, loc)
  if self.install(run) {
    self.start(run)
  }
}

///|
fn HoldGate::is_current(self : HoldGate, run : HoldRun) -> Bool {
  self.active is Some(active) && physical_equal(active, run)
}

///|
fn HoldGate::install(self : HoldGate, run : HoldRun) -> Bool {
  self.cancel()
  // A release callback can start a newer transition itself.
  if self.active is Some(_) {
    @signals.untracked(run.give_up)
    return false
  }
  run.acknowledged.val = self.always_acknowledged || self.pending_ack
  self.pending_ack = false
  self.active = Some(run)
  true
}

///|
fn HoldGate::own_run(self : HoldGate, run : HoldRun) -> Unit {
  if run.node.alive() {
    run.unown = run.node.owns_while(fn() { self.finish(run, Cancelled) })
  } else {
    self.finish(run, Cancelled)
  }
}

///|
#derive(Eq)
priv enum HoldRead {
  Waiting
  Ready
  Cancelled
  Discarded
}

///|
fn HoldGate::read(self : HoldGate, run : HoldRun) -> HoldRead {
  guard self.is_current(run) else { return Discarded }
  guard (run.still)() else { return Cancelled }
  collecting_hold(Checking(self, run, Map([])), fn() {
    let mut ready = (run.check)()
    // Read every condition, including those said by another condition as it is checked.
    for i = 0; i < run.conds.length(); i = i + 1 {
      if !(run.conds[i].ready)() {
        ready = false
      }
    }
    if ready { Ready } else { Waiting }
  })
}

///|
fn HoldGate::start(self : HoldGate, run : HoldRun) -> Unit {
  self.own_run(run)
  let result = @signals.untracked(fn() { self.read(run) })
  guard self.is_current(run) else { return }
  if result != Waiting || run.most == 0.0 {
    self.finish(run, if result == Waiting { Ready } else { result })
    return
  }
  let node = run.node
  let t0 = node.cause_at()
  let deadline = t0 + run.most
  if !(deadline < @double.infinity) {
    @halt.saying("HoldGate deadline is out of range at " + source_place(run.loc))
  }
  if deadline <= t0 {
    self.finish(run, Ready)
    return
  }

  let first = Ref(Waiting)
  // The node owns the wait directly so it can stop on settlement as well as on node disposal. Its signal changes
  // use the tree's structure machinery for the cause time, with drawing left to the bindings that read pending.
  let owner = @signals.set_owner(None)
  let unwatch = node.tree.structured(
    fn() {
      let result = self.read(run)
      first.val = result
      result
    },
    fn(result) {
      if result != Waiting {
        self.finish(run, result)
      }
    },
    at_start=false,
    draws=false,
  )
  @signals.set_owner(owner) |> ignore
  if !self.is_current(run) {
    unwatch()
    return
  }
  run.unwatch = unwatch
  if first.val != Waiting {
    self.finish(run, first.val)
    return
  }

  run.first = run.conds.get(0).map(fn(c) { c.loc })
  let log = node.tree.hold_log()
  if self.holding.watched() {
    run.acknowledged.val = true
  }
  let sample : HoldSample = { loc: run.loc, start: t0, acknowledged: run.acknowledged }
  log.active.push(sample)
  run.sample = Some((log, sample))
  // Mark the gate pending and arm the one deadline before notifying any pending bindings.
  @signals.start_batch()
  run.untime = node.at_moment(deadline, loc=run.loc, fn() {
    let result = if @signals.untracked(run.still) { Ready } else { Cancelled }
    self.finish(run, result)
  })
  if self.is_current(run) {
    self.holding.set(true)
  } else {
    (run.untime)()
  }
  @signals.end_batch()
}

///|
fn HoldGate::finish(self : HoldGate, run : HoldRun, result : HoldRead) -> Unit {
  guard self.is_current(run) else { return }
  if self.once && !self.through && result == Ready {
    self.through = true
    self.staged = []
  }
  if run.sample is Some((_, sample)) && self.holding.watched() {
    sample.acknowledged.val = true
  }
  self.active = None
  (run.untime)()
  let unwatch = run.unwatch
  run.unwatch = fn() {  }
  unwatch()
  (run.unown)()
  if run.sample is Some((log, sample)) {
    if log.active.search_by(fn(it) { physical_equal(it, sample) }) is Some(i) {
      log.active.remove(i) |> ignore
    }
    if result == Ready && sample.fault(run.node.tree.logic_said()) is Some(fault) {
      hold_log_push(log.faults, fault)
    }
  }
  self.holding.set(false)
  match result {
    Ready => @signals.untracked(run.go)
    Cancelled => @signals.untracked(run.give_up)
    _ => ()
  }
}

///|
/// Release a queued or pending transition. `give_up=false` leaves its subscription leases with the caller.
pub fn HoldGate::cancel(self : HoldGate, give_up? : Bool = true) -> Unit {
  if self.active is Some(run) {
    self.finish(run, if give_up { Cancelled } else { Discarded })
  }
}

///|
/// Cancel the gate, giving up its wait by default.
pub fn HoldGate::stop(self : HoldGate, give_up? : Bool = true) -> Unit {
  self.cancel(give_up~)
}

///|
priv struct HoldSample {
  loc : SourceLoc
  start : Double
  acknowledged : Ref[Bool]
}

///|
priv struct HoldLog {
  tree : Tree
  active : Array[HoldSample]
  faults : Array[String]
  waterfalls : Array[String]
  mut unown : () -> Unit
}

///|
/// The most faults (and the most serial reads) a tree's log keeps: the latest, the earliest let go as one more comes, so
/// a window that runs long holds no more of them than this.
let hold_log_max : Int = 256

///|
/// `said` put at the end of `list`, the earliest of it let go where that would make it more than hold_log_max.
fn hold_log_push(list : Array[String], said : String) -> Unit {
  list.push(said)
  if list.length() > hold_log_max {
    list.remove(0) |> ignore
  }
}

///|
// kept across runs: each tree owns its log until disposal, and hold_reset clears the run's diagnostics
let hold_logs : Array[HoldLog] = []

///|
fn Tree::hold_log(self : Tree) -> HoldLog {
  if hold_logs.iter().find_first(fn(log) { physical_equal(log.tree, self) }) is Some(log) {
    return log
  }
  let log : HoldLog = { tree: self, active: [], faults: [], waterfalls: [], unown: fn() {  } }
  hold_logs.push(log)
  log.unown = self.root().owns_while(fn() {
    if hold_logs.search_by(fn(it) { physical_equal(it, log) }) is Some(i) {
      hold_logs.remove(i) |> ignore
    }
    log.unown = fn() {  }
  })
  log
}

///|
fn HoldSample::fault(self : HoldSample, end : Double) -> String? {
  let elapsed = end - self.start
  if !self.acknowledged.val && end >= self.start + silent_hold_ms {
    return Some(
      "[SILENT_HOLD] Hold at \{source_place(self.loc)} waited \{elapsed}ms (>= \{silent_hold_ms}ms) with no UI acknowledgment. " +
      "Fix: bind HoldGate::is_pending() to a visible pending or disabled state, or acknowledge optimistic feedback via HoldGate::acknowledge().",
    )
  }
  if self.acknowledged.val && end >= self.start + long_hold_ms {
    return Some(
      "[LONG_HOLD] Hold at \{source_place(self.loc)} waited \{elapsed}ms (>= \{long_hold_ms}ms). " +
      "Fix: cap local HoldGate most to 300ms or less and let remote waits enter View::bones immediately.",
    )
  }
  None
}

///|
/// Settled faults and those of currently pending transitions, read at the tree's logic time.
pub fn Tree::hold_faults(self : Tree) -> Array[String] {
  guard hold_logs.iter().find_first(fn(log) { physical_equal(log.tree, self) }) is Some(log) else { return [] }
  let out = log.faults.copy()
  for sample in log.active {
    if sample.fault(self.logic_said()) is Some(fault) {
      out.push(fault)
    }
  }
  out
}

///|
/// The serial async reads recorded on this tree.
pub fn Tree::waterfall_faults(self : Tree) -> Array[String] {
  match hold_logs.iter().find_first(fn(log) { physical_equal(log.tree, self) }) {
    Some(log) => log.waterfalls.copy()
    None => []
  }
}

///|
/// Whether any collection context is still open after the caller has returned.
pub fn hold_marks_left() -> Bool {
  !hold_gates.is_empty()
}

///|
/// Clear the collection contexts and diagnostics at the beginning of a new run.
pub fn hold_reset() -> Unit {
  hold_gates.clear()
  for log in hold_logs {
    (log.unown)()
    log.unown = fn() {  }
    log.active.clear()
    log.faults.clear()
    log.waterfalls.clear()
  }
  hold_logs.clear()
}
