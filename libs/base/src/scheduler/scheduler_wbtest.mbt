// The lane's tests on a runtime of the test's own clock (`@effect.Runtime::new`): each task is a fiber the test forks,
// holding its slot until the test lets it end (`Rig::finish`); `run_ready` runs every fiber until none is ready, so
// what starts and what waits is read off the log at each step. Nothing waits on real time.

///|
priv struct Rig {
  rt : @effect.Runtime
  lane : Scheduler
  /// What happened, in order: `start k`, `end k`, `preempted k`, `gave up k`.
  log : Array[String]
  /// What lets each task end, by key.
  gates : Map[String, @effect.Deferred[Unit]]
  fibers : Map[String, @effect.Fiber[Unit]]
}

///|
fn Rig::new(width? : Int = 2) -> Rig {
  {
    rt: @effect.Runtime::new(),
    lane: Scheduler::new(width~),
    log: [],
    gates: Map([]),
    fibers: Map([]),
  }
}

///|
/// A task of `key` asked at `priority`, holding its slot until `finish(key)`.
fn Rig::ask(self : Rig, key : String, priority : Int) -> Unit {
  let gate : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.gates.set(key, gate)
  let f = self.rt.fork(() => {
    self.lane.run(key, priority, _ => {
      self.log.push("start \{key}")
      gate.wait()
      self.log.push("end \{key}")
    })
  })
  self.fibers.set(key, f)
}

///|
/// An idle task of `key` in pieces: each piece waits for its gate, and it stops where it is told to give way.
fn Rig::ask_idle(self : Rig, key : String) -> Unit {
  let gate : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.gates.set(key, gate)
  let f = self.rt.fork(() => {
    self.lane.run(key, priority_idle, preempt => {
      self.log.push("start \{key}")
      let given_way = @effect.race(
        async fn() {
          gate.wait()
          false
        },
        async fn() {
          preempt.wait()
          true
        },
      )
      if given_way {
        assert_true(preempt.is_preempted())
        self.log.push("preempted \{key}")
      } else {
        self.log.push("end \{key}")
      }
    })
  })
  self.fibers.set(key, f)
}

///|
fn Rig::finish(self : Rig, key : String) -> Unit {
  ignore(self.gates[key].succeed(()))
  ignore(self.rt.run_ready())
}

///|
fn Rig::step(self : Rig) -> Unit {
  ignore(self.rt.run_ready())
}

///|
/// The log since it was last taken.
fn Rig::took(self : Rig) -> Array[String] {
  let out = [..self.log]
  self.log.clear()
  out
}

///|
test "urgent tasks take the room kept for them past the lane's width, the shown ones only its width" {
  let rig = Rig::new()
  rig.ask("s1", priority_shown)
  rig.ask("s2", priority_shown)
  rig.ask("s3", priority_shown)
  rig.ask("f1", priority_focused)
  rig.ask("a1", priority_asked)
  rig.ask("a2", priority_asked)
  rig.step()
  // s1, s2 fill the width and s3 waits; f1 and a1, urgent, take the room kept past it as each is asked; a2 waits
  assert_eq(
    rig.took(),
    ["start s1", "start s2", "start f1", "start a1"],
  )
  rig.finish("a1")
  // the room has one free: a2 (urgent) before s3 (whose width is full)
  assert_eq(
    rig.took(),
    ["end a1", "start a2"],
  )
  rig.finish("s1")
  assert_eq(
    rig.took(),
    ["end s1"],
  )
  rig.finish("a2")
  assert_eq(
    rig.took(),
    ["end a2"],
  )
  rig.finish("f1")
  assert_eq(
    rig.took(),
    ["end f1", "start s3"],
  )
}

///|
test "prioritize raises what its prefix matches, and letting it go puts back what each was asked at" {
  let rig = Rig::new(width=1)
  rig.ask("hold", priority_shown)
  rig.step()
  rig.ask("t:1/a", priority_shown)
  rig.ask("t:2/a", priority_shown)
  rig.ask("t:2/b", priority_shown)
  rig.step()
  rig.lane.prioritize("open", Some("t:2/"), boost=priority_shown + 1)
  assert_eq(
    rig.lane.pending(),
    ["hold@10 running", "t:1/a@10", "t:2/a@11", "t:2/b@11"],
  )
  // let go before anything raised began: each back to what it was asked at, in the order asked
  rig.lane.prioritize("open", None)
  assert_eq(
    rig.lane.pending(),
    ["hold@10 running", "t:1/a@10", "t:2/a@10", "t:2/b@10"],
  )
  rig.lane.prioritize("open", Some("t:2/b"), boost=priority_shown + 1)
  rig.finish("hold")
  assert_eq(
    rig.took(),
    ["start hold", "end hold", "start t:2/b"],
  )
  rig.lane.prioritize("open", None)
  rig.finish("t:2/b")
  assert_eq(
    rig.took(),
    ["end t:2/b", "start t:1/a"],
  )
  // raised to the urgent, a waiting one goes at once in the room kept for them
  rig.lane.prioritize("open", Some("t:2/a"))
  rig.step()
  assert_eq(
    rig.took(),
    ["start t:2/a"],
  )
}

///|
test "the background runs one at a time, held back by what is shown and by a request in sight, then woken" {
  let rig = Rig::new()
  rig.ask("shown", priority_shown)
  rig.ask("bg1", priority_background)
  rig.ask("bg2", priority_background)
  rig.step()
  assert_eq(
    rig.took(),
    ["start shown"],
  )
  let end_fg = rig.lane.foreground_begin()
  rig.finish("shown")
  // nothing shown is left, but a request in sight is under way: the background still waits
  assert_eq(
    rig.took(),
    ["end shown"],
  )
  end_fg()
  end_fg()
  rig.step()
  // one at a time, though the width has room for two
  assert_eq(
    rig.took(),
    ["start bg1"],
  )
  rig.ask("detail", priority_detail)
  rig.step()
  assert_eq(
    rig.took(),
    ["start detail"],
  )
  rig.finish("bg1")
  // detail runs: the next of the background waits for it
  assert_eq(
    rig.took(),
    ["end bg1"],
  )
  let idle_seen = Ref(0)
  rig.lane.on_idle(() => idle_seen.val += 1)
  rig.finish("detail")
  assert_eq(
    rig.took(),
    ["end detail", "start bg2"],
  )
  rig.finish("bg2")
  assert_eq(idle_seen.val, 1)
  assert_false(rig.lane.busy())
}

///|
test "the background asks nothing of an idle step under way: it waits for it, as nothing idle starts meanwhile" {
  let rig = Rig::new()
  rig.ask_idle("fill")
  rig.step()
  assert_eq(rig.took(), ["start fill"])
  rig.ask("bg", priority_background)
  rig.ask_idle("fill2")
  rig.step()
  assert_eq(rig.took(), [])
  rig.finish("fill")
  // the background goes, and the idle one waits behind it
  assert_eq(rig.took(), ["end fill", "start bg"])
  rig.finish("bg")
  assert_eq(rig.took(), ["end bg", "start fill2"])
}

///|
test "an idle task is told to give way as anything above the background is asked, a detail too" {
  let rig = Rig::new()
  rig.ask_idle("fill")
  rig.step()
  rig.ask("detail", priority_detail)
  rig.step()
  assert_eq(rig.took(), ["start fill", "start detail", "preempted fill"])
  rig.finish("detail")
  assert_false(rig.lane.busy())
}

///|
test "an idle task raised by prioritize does not give way to its own urgency, and does once let go" {
  let rig = Rig::new()
  rig.lane.prioritize("open", Some("t:"))
  rig.ask_idle("t:fill")
  rig.step()
  rig.ask("shown", priority_shown)
  rig.step()
  // raised to focused: what is shown beside it is no reason for it to give way
  assert_eq(rig.took(), ["start t:fill", "start shown"])
  rig.lane.prioritize("open", None)
  rig.step()
  // idle again, with something above the background running: it gives way
  assert_eq(rig.took(), ["preempted t:fill"])
  rig.finish("shown")
  assert_false(rig.lane.busy())
}

///|
test "a task between the background and a detail runs in the lane's width, as the TypeScript lane's bounds have it" {
  let rig = Rig::new()
  rig.ask("one", priority_background + 1)
  rig.ask("two", priority_background + 1)
  rig.ask("three", priority_background + 1)
  rig.step()
  assert_eq(rig.took(), ["start one", "start two"])
}

///|
test "an idle task gives way as a request in sight begins, and waits while it is under way" {
  let rig = Rig::new()
  rig.ask_idle("fill")
  rig.step()
  let end_fg = rig.lane.foreground_begin()
  rig.step()
  assert_eq(
    rig.took(),
    ["start fill", "preempted fill"],
  )
  rig.ask_idle("fill2")
  rig.step()
  assert_eq(rig.took(), [])
  end_fg()
  rig.step()
  assert_eq(
    rig.took(),
    ["start fill2"],
  )
  // what is shown asked: it starts beside the idle one at once, and the idle one gives way
  rig.ask("shown", priority_shown)
  rig.step()
  assert_eq(
    rig.took(),
    ["start shown", "preempted fill2"],
  )
}

///|
test "an idle task asked while something else is waiting is not told to give way before it starts" {
  let rig = Rig::new()
  rig.ask("shown", priority_shown)
  rig.ask_idle("fill")
  rig.step()
  assert_eq(
    rig.took(),
    ["start shown"],
  )
  rig.finish("shown")
  assert_eq(
    rig.took(),
    ["end shown", "start fill"],
  )
  rig.finish("fill")
  assert_eq(
    rig.took(),
    ["end fill"],
  )
}

///|
test "a fiber interrupted while it runs gives its slot back and what waits goes on" {
  let rig = Rig::new(width=1)
  rig.ask("a", priority_shown)
  rig.ask("b", priority_shown)
  rig.ask("c", priority_shown)
  rig.step()
  assert_eq(
    rig.took(),
    ["start a"],
  )
  rig.fibers["a"].interrupt()
  rig.step()
  assert_eq(
    rig.took(),
    ["start b"],
  )
  // one interrupted while it waits leaves the queue: nothing runs it later
  rig.fibers["c"].interrupt()
  rig.step()
  assert_eq(
    rig.lane.pending(),
    ["b@10 running"],
  )
  rig.finish("b")
  assert_eq(
    rig.took(),
    ["end b"],
  )
  assert_false(rig.lane.busy())
  assert_true(rig.fibers["a"].is_done())
  assert_true(rig.fibers["c"].is_done())
}

///|
test "a fiber interrupted in the turn its slot was given never holds it" {
  let rig = Rig::new(width=1)
  rig.ask("a", priority_shown)
  rig.ask("b", priority_shown)
  rig.ask("c", priority_shown)
  rig.step()
  // a ends and b is given the slot; b is interrupted before it ever runs again
  ignore(rig.gates["a"].succeed(()))
  rig.fibers["b"].interrupt()
  rig.step()
  assert_eq(
    rig.took(),
    ["start a", "end a", "start c"],
  )
  rig.finish("c")
  assert_false(rig.lane.busy())
}

///|
test "one key runs once at a time: asked again while it runs, the second waits for the first" {
  let rig = Rig::new()
  rig.ask("k", priority_shown)
  rig.step()
  let gate : @effect.Deferred[Unit] = @effect.Deferred::new()
  ignore(
    rig.rt.fork(() => rig.lane.run("k", priority_shown, _ => {
      rig.log.push("start k again")
      gate.wait()
    })),
  )
  rig.ask("other", priority_shown)
  rig.step()
  assert_eq(
    rig.took(),
    ["start k", "start other"],
  )
  rig.finish("k")
  assert_eq(
    rig.took(),
    ["end k", "start k again"],
  )
}
