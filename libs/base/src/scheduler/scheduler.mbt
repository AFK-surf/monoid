// One lane of a client's requests to one peer, run a few at a time, the most urgent first: the device base in
// TypeScript's scheduler (client/core-ts/src/sync/scheduler.ts), one `Scheduler` a lane. What exists to be done is the
// program's to say; what a person sees only makes some of it more urgent (`prioritize`).
//
// How many run at once, by how urgent the most urgent waiting one is now (the bounds the TypeScript lane's):
//   - `priority_focused` and up (urgent): the lane's `width` and `urgent_room` more;
//   - above `priority_background`, below that (normal): the lane's `width`;
//   - above `priority_idle`, up to `priority_background` (background): one at a time, and only while nothing above the
//     background waits or runs and no request in a person's sight is under way (`foreground_begin`);
//   - `priority_idle` and below (idle): alone, once nothing else waits or runs and no such request is under way.
// What is idle gives way: as anything above the background is asked or under way, or a request in a person's sight
// begins, the idle task running is told (`Preempt`), to stop where it can and let its slot go. The background does not
// make it give way: it waits for that step of it to end, as nothing idle starts while it waits.
//
// A task runs in the fiber that asked for it (`Scheduler::run`): one interrupted while it waits leaves the queue, one
// interrupted while it runs gives its slot back, both in a `defer`, so nothing waits behind a slot nobody holds. One
// key runs once at a time: asked again while it runs, the second waits for the first to end.

///|
/// A person waits on it (an answer is shown once it is done).
pub let priority_asked : Int = 30

///|
/// What a person has open.
pub let priority_focused : Int = 20

///|
/// Behind something shown.
pub let priority_shown : Int = 10

///|
/// What shows only once opened: after what shows in brief.
pub let priority_detail : Int = 5

///|
/// Kept current in the background.
pub let priority_background : Int = 0

///|
/// What was opened and let go, brought whole all the same: after everything else.
pub let priority_idle : Int = -10

///|
/// A task waiting for its slot.
priv struct Waiting {
  key : String
  /// What it was asked at, before what is made urgent (`prioritize`) raises it.
  base : Int
  seq : Int
  /// Given its slot: told once it may go.
  go : @effect.Deferred[Unit]
  mut granted : Bool
}

///|
/// One lane's tasks, waiting and running.
pub struct Scheduler {
  /// How many run at once of what is shown, and how many more of what is urgent.
  width : Int
  urgent_room : Int
  priv waiting : Array[Waiting]
  /// What runs, by key: what it was asked at.
  priv running : Map[String, Int]
  /// The priority what each prefix matches gets while who asked says so (`prioritize`), by who asked.
  priv boosts : Map[String, (String, Int)]
  priv mut seq : Int
  /// Requests in a person's sight that are no task of the lane (`foreground_begin`), under way now.
  priv mut foreground : Int
  /// Told once what is idle is to give way (`Preempt::wait`): made as one waits, let go as it is told.
  priv mut preempt : @effect.Deferred[Unit]?
  /// Told as the lane has nothing left to run or running, a task of it just over.
  priv mut on_idle : () -> Unit
}

///|
/// A lane running `width` at once of what is shown, and `urgent_room` more of what is urgent.
pub fn Scheduler::new(width? : Int = 2, urgent_room? : Int = 2) -> Scheduler {
  {
    width,
    urgent_room,
    waiting: [],
    running: Map([]),
    boosts: Map([]),
    seq: 0,
    foreground: 0,
    preempt: None,
    on_idle: () => (),
  }
}

///|
/// `f` is called each time the lane comes to have nothing waiting or running (a task of it just over, or a request
/// in a person's sight ended with none).
pub fn Scheduler::on_idle(self : Scheduler, f : () -> Unit) -> Unit {
  self.on_idle = f
}

///|
/// How urgent a task of `key` asked at `base` is now: raised by what is made urgent.
fn Scheduler::effective(self : Scheduler, key : String, base : Int) -> Int {
  let mut p = base
  for _, boost in self.boosts {
    let (prefix, at) = boost
    if at > p && key.has_prefix(prefix) {
      p = at
    }
  }
  p
}

///|
/// Whether anything waiting or running is more urgent than `than` now.
fn Scheduler::above(self : Scheduler, than : Int) -> Bool {
  for key, base in self.running {
    if self.effective(key, base) > than {
      return true
    }
  }
  for w in self.waiting {
    if self.effective(w.key, w.base) > than {
      return true
    }
  }
  false
}

///|
/// Whether what is idle gives way: a request in a person's sight under way, or anything above the background.
fn Scheduler::urgent(self : Scheduler) -> Bool {
  self.foreground > 0 || self.above(priority_background)
}

///|
/// What is idle is told to give way.
fn Scheduler::preempt_idle(self : Scheduler) -> Unit {
  guard self.preempt is Some(d) else { return }
  self.preempt = None
  ignore(d.succeed(()))
}

///|
/// Starts what may start now, the most urgent first, then the oldest.
fn Scheduler::pump(self : Scheduler) -> Unit {
  if self.urgent() {
    self.preempt_idle()
  }
  while true {
    let mut best = -1
    let mut best_p = 0
    for i, w in self.waiting {
      if self.running.contains(w.key) {
        continue
      }
      let p = self.effective(w.key, w.base)
      if best < 0 || p > best_p || (p == best_p && w.seq < self.waiting[best].seq) {
        best = i
        best_p = p
      }
    }
    if best < 0 {
      return
    }
    let busy = self.running.length()
    if best_p >= priority_focused {
      if busy >= self.width + self.urgent_room {
        return
      }
    } else if best_p > priority_background {
      if busy >= self.width {
        return
      }
    } else if best_p > priority_idle {
      // (one at a time, behind everything more urgent: what is asked next never waits behind more than one gone)
      if busy >= self.width ||
        self.foreground > 0 ||
        self.above(priority_background) {
        return
      }
      for key, base in self.running {
        if self.effective(key, base) <= priority_background {
          return
        }
      }
    } else if busy > 0 || self.foreground > 0 || self.above(priority_idle) {
      return
    }
    let w = self.waiting.remove(best)
    w.granted = true
    self.running.set(w.key, w.base)
    ignore(w.go.succeed(()))
  }
}

///|
/// What a task is told of giving way: asked at once, or waited for. Only a task idle now (its priority as raised by
/// `prioritize`, `priority_idle` or below) is ever to give way, so one raised out of idle does not take its own
/// urgency for a reason to.
pub struct Preempt {
  priv lane : Scheduler
  priv key : String
  priv base : Int
}

///|
/// Whether it is to give way now: while it is idle, and a request in a person's sight is under way or anything above
/// the background waits or runs.
pub fn Preempt::is_preempted(self : Preempt) -> Bool {
  self.lane.effective(self.key, self.base) <= priority_idle && self.lane.urgent()
}

///|
/// Returns once it is to give way (at once where it is already): what an idle task races its work with. A task not
/// idle waits until it is, and is to give way.
pub async fn Preempt::wait(self : Preempt) -> Unit {
  while !self.is_preempted() {
    let d = match self.lane.preempt {
      Some(d) => d
      None => {
        let d = @effect.Deferred::new()
        self.lane.preempt = Some(d)
        d
      }
    }
    d.wait()
  }
}

///|
/// Runs `task` in this fiber once its slot is free: by `key` (one run of a key at a time), at `priority`, raised by
/// what is made urgent. Its slot is given back however it ends, interrupted too, and what waits behind it goes on.
pub async fn[T] Scheduler::run(
  self : Scheduler,
  key : String,
  priority : Int,
  task : async (Preempt) -> T,
) -> T {
  self.seq += 1
  let w : Waiting = { key, base: priority, seq: self.seq, go: @effect.Deferred::new(), granted: false }
  self.waiting.push(w)
  defer self.leave(w)
  self.pump()
  w.go.wait()
  task({ lane: self, key, base: priority })
}

///|
/// A task's end, or its giving up while it waited: its slot or its place let go, and what may start now started.
fn Scheduler::leave(self : Scheduler, w : Waiting) -> Unit {
  if w.granted {
    self.running.remove(w.key)
  } else {
    match self.waiting.search_by(x => physical_equal(x, w)) {
      Some(i) => ignore(self.waiting.remove(i))
      None => ()
    }
  }
  self.pump()
  if self.running.is_empty() && self.waiting.is_empty() && self.foreground == 0 {
    (self.on_idle)()
  }
}

///|
/// A request in a person's sight that is no task of the lane begins: until the function given back is called (once;
/// again does nothing), the background and what is idle wait, and what is idle running gives way.
pub fn Scheduler::foreground_begin(self : Scheduler) -> () -> Unit {
  self.foreground += 1
  self.preempt_idle()
  let mut ended = false
  () => {
    if ended {
      return
    }
    ended = true
    self.foreground -= 1
    self.pump()
    if self.foreground == 0 && self.running.is_empty() && self.waiting.is_empty() {
      (self.on_idle)()
    }
  }
}

///|
/// Makes what `prefix` matches at least `boost` while `slot` says so (what a person has open); `None` lets it go, and
/// what it raised that has not begun goes back to what it was asked at.
pub fn Scheduler::prioritize(
  self : Scheduler,
  slot : String,
  prefix : String?,
  boost? : Int = priority_focused,
) -> Unit {
  match prefix {
    Some(p) => self.boosts.set(slot, (p, boost))
    None => self.boosts.remove(slot)
  }
  self.pump()
}

///|
/// Whether a task of `key` waits or runs.
pub fn Scheduler::queued(self : Scheduler, key : String) -> Bool {
  self.running.contains(key) || self.waiting.iter().any(w => w.key == key)
}

///|
/// Whether anything waits or runs.
pub fn Scheduler::busy(self : Scheduler) -> Bool {
  !self.running.is_empty() || !self.waiting.is_empty()
}

///|
/// What runs and waits, for tests: `key@priority`, as urgent as each is now, what runs first (` running`).
pub fn Scheduler::pending(self : Scheduler) -> Array[String] {
  let out : Array[String] = []
  for key, base in self.running {
    out.push("\{key}@\{self.effective(key, base)} running")
  }
  for w in self.waiting {
    out.push("\{w.key}@\{self.effective(w.key, w.base)}")
  }
  out
}
