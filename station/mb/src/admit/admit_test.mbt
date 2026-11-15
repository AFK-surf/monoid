// Which waiting task starts, and when, by what is measured (what the system says of its memory; never how busy the
// CPUs are) and nothing estimated; who has the screen (once station/test/admit.test.ts's, admit-small.test.ts's).

///|
fn w(id : String, session : String, queued_at : Double, screen? : Bool = false, small? : Bool = false) -> @admit.Waiting {
  { id, session, screen, queued_at, small }
}

///|
fn r(id : String, screen? : Bool = false, small? : Bool = false) -> @admit.Started {
  { id, screen, small }
}

///|
fn never(_s : String) -> Double? {
  None
}

///|
let free : @admit.Claims = { held: false, asked: None }

///|
fn normal(
  waiting : Array[@admit.Waiting],
  running : Array[@admit.Started],
  last? : (String) -> Double? = never,
  claims? : @admit.Claims = free,
  person? : Bool = false,
) -> @admit.Picked? {
  @admit.pick(waiting, running, Some("normal"), person, last, claims)
}

///|
fn c(job : String, pid : Int, held? : Bool = false, since? : Double, at? : Double) -> @admit.Claim {
  { job, pid, at: at.unwrap_or(pid.to_double()), held, since }
}

///|
test "with none of the queue running, the first starts" {
  assert_eq(normal([w("a", "s", 1), w("b", "s", 2)], []), Some(Start(w("a", "s", 1))))
}

///|
test "busy CPUs hold no task back: another starts beside those running at once" {
  assert_eq(normal([w("a", "s", 1)], [r("x"), r("y")]), Some(Start(w("a", "s", 1))))
}

///|
test "no ordinary task starts while the memory is under pressure, not even the first" {
  for pressure in ["high", "critical"] {
    assert_eq(@admit.pick([w("a", "s", 1)], [], Some(pressure), false, never, free), Some(Wait("memory")))
  }
  // Not read: nothing holds it back.
  assert_eq(@admit.pick([w("a", "s", 1)], [], None, false, never, free), Some(Start(w("a", "s", 1))))
}

///|
test "a task that uses the screen waits for the other one, and lets those that do not go first" {
  let running = [r("x", screen=true)]
  assert_eq(normal([w("a", "s", 1, screen=true)], running), Some(Wait("screen")))
  assert_eq(normal([w("a", "s", 1, screen=true), w("b", "s", 2)], running), Some(Start(w("b", "s", 2))))
}

///|
test "a task that uses the screen throughout waits while a command holds it, and for one that asked before it came" {
  let holding = @admit.claims_held([c("x", 1, held=true, at=0)])
  assert_eq(normal([w("a", "s", 1, screen=true)], [], claims=holding), Some(Wait("screen")))
  assert_eq(normal([w("a", "s", 1, screen=true), w("b", "s", 2)], [], claims=holding), Some(Start(w("b", "s", 2))))
  let asked = @admit.claims_held([c("x", 1, at=5)])
  assert_eq(normal([w("a", "s", 5, screen=true)], [], claims=asked), Some(Wait("screen")))
  // it came first
  assert_eq(normal([w("a", "s", 4, screen=true)], [], claims=asked), Some(Start(w("a", "s", 4, screen=true))))
}

///|
test "the session whose task last started longest ago goes first: ten of one do not keep another's behind them" {
  let waiting = [w("a1", "a", 1), w("a2", "a", 2), w("a3", "a", 3), w("b1", "b", 4)]
  let last = (s : String) => if s == "a" { Some(100.0) } else { None }
  assert_eq(normal(waiting, [], last~), Some(Start(w("b1", "b", 4))))
  assert_eq(@admit.place(waiting, "b1", last), Some(1))
  assert_eq(@admit.place(waiting, "a1", last), Some(2))
  assert_eq(@admit.place(waiting, "a3", last), Some(4))
  assert_eq(@admit.place(waiting, "gone", last), None)
}

///|
test "the screen goes to the first command that asked while no task has it, and at once to one whose task has it" {
  assert_eq(@admit.served([c("a", 1), c("b", 2), c("a", 3)], [], 9, false), [
    c("a", 1, held=true, since=9),
    c("b", 2),
    c("a", 3, held=true, since=9),
  ])
  // b's until it gives it back
  assert_eq(@admit.served([c("b", 2, held=true), c("a", 3)], [], 9, false), [c("b", 2, held=true), c("a", 3)])
  // inside a task that has it throughout
  assert_eq(@admit.served([c("a", 1), c("t", 2)], ["t"], 9, false), [c("a", 1), c("t", 2, held=true, since=9)])
  assert_eq(@admit.claims_held([c("b", 2, held=true), c("a", 3), c("c", 4)]), { held: true, asked: Some(3) })
  assert_eq(@admit.claims_held([]), { held: false, asked: None })
}

///|
test "while a person uses the screen nothing more is given it; what has it goes on, and a command of its own still gets it" {
  // none given
  assert_eq(@admit.served([c("a", 1), c("b", 2)], [], 9, true), [c("a", 1), c("b", 2)])
  // a's own
  assert_eq(@admit.served([c("a", 1, held=true, since=5), c("a", 3)], [], 9, true), [
    c("a", 1, held=true, since=5),
    c("a", 3, held=true, since=9),
  ])
  // the queue's tasks that use the screen throughout wait for the person, said so; the others start
  let screen = w("s", "x", 1, screen=true)
  assert_eq(normal([screen], [], person=true), Some(Wait("person")))
  assert_eq(normal([screen, w("p", "y", 2)], [], person=true), Some(Start(w("p", "y", 2))))
  // another task's having it says so before the person
  assert_eq(normal([screen], [], person=true, claims={ held: true, asked: None }), Some(Wait("screen")))
}

///|
test "a command that has held the screen long while another waits is told; none is while none waits" {
  let long = c("vm", 1, held=true, since=0, at=0)
  // no one waits
  assert_eq(@admit.overstaying([long], @admit.held_long_ms), [])
  assert_eq(@admit.overstaying([long, c("pic", 2, at=0)], @admit.held_long_ms), [long])
  // not long yet
  assert_eq(@admit.overstaying([long, c("pic", 2, at=0)], @admit.held_long_ms - 1), [])
  // an earlier station's: since it asked
  assert_eq(@admit.overstaying([c("old", 3, held=true, at=0), c("pic", 2, at=0)], @admit.held_long_ms), [c("old", 3, held=true, at=0)])
}

///|
test "one small task can run beside a busy build, but still waits for critical memory and another small task" {
  let build = r("build")
  let picture = w("picture", "a", 1, small=true)
  let next = w("next", "b", 2, small=true)
  assert_eq(normal([picture], [build]), Some(Start(picture)))
  assert_eq(normal([next], [build, r("picture", small=true)]), Some(Wait("small")))
  assert_eq(@admit.pick([picture], [build], Some("critical"), false, never, free), Some(Wait("memory")))
}

///|
test "under high memory pressure a small task still starts, and only it (#4355)" {
  let build = r("build")
  let look = w("look", "a", 2, small=true)
  let other = w("other", "b", 1)
  let high = (waiting, running) => @admit.pick(waiting, running, Some("high"), false, never, free)
  assert_eq(high([other, look], [build]), Some(Start(look)))
  assert_eq(high([other], []), Some(Wait("memory")))
  assert_eq(high([look], [build, r("x", small=true)]), Some(Wait("small")))
}

///|
test "small tasks are fair between sessions and do not hold up a ready ordinary task" {
  let a = w("a", "a", 1, small=true)
  let b = w("b", "b", 2, small=true)
  let plain = w("normal", "a", 3)
  let last = (s : String) => if s == "a" { Some(10.0) } else { None }
  assert_eq(normal([a, b], [], last~), Some(Start(b)))
  assert_eq(normal([a, plain], [r("other", small=true)], last~), Some(Start(plain)))
  assert_eq(@admit.pick([a], [r("other", small=true)], Some("critical"), false, last, free), Some(Wait("memory")))
}

///|
test "a service's pause grows with each quick end, and a steady run starts again at once" {
  assert_eq([0, 1, 2, 3, 5, 6, 9].map(n => @admit.restart_pause(n, 100)), [1000, 2000, 4000, 8000, 32000, 60000, 60000])
  assert_eq(@admit.restart_pause(4, 60000), 0)
}
