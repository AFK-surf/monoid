// `Shell::turn` as a window's loop runs it: never `run`, never a wait. The runtime goes by a clock the test sets (a
// live one, as a window's), the shell is a test's (`Shell::stood_in`, nothing of the Rust shell linked), and its
// answers come through a queue of the test's as through shell.c's, taken at the turn (`Shell::turn_taking`, which
// `turn` is over `Shell::pump`).

///|
/// A test's shell whose answers wait in `queue` till a turn takes them; `at_once`: each call is answered into it as
/// it is asked (by the shell's thread, while the turn that asked it runs).
priv struct Turned {
  shell : Shell
  asked : Array[(Int64, String)]
  queue : Array[(Int64, Json)]
}

///|
fn Turned::new(rt : @effect.Runtime, at_once? : Bool = false) -> Turned {
  let asked : Array[(Int64, String)] = []
  let queue : Array[(Int64, Json)] = []
  let shell = Shell::stood_in(
    rt,
    calls=(id, op, _, _) => {
      asked.push((id, op))
      if at_once {
        queue.push((id, { "op": Json::string(op) }))
      }
    },
    asks=(_, _) => Json::null(),
    draws=n => Bytes::make(n, b'\x00'),
  )
  { shell, asked, queue }
}

///|
fn Turned::turn(self : Turned) -> Int64? {
  self.shell.turn_taking(() => {
    guard !self.queue.is_empty() else { return false }
    let came = self.queue.copy()
    self.queue.clear()
    for a in came {
      self.shell.answer(a.0, a.1)
    }
    true
  })
}

///|
test "turn drives a fiber through timers and an answer, saying when it is next due" {
  let clock = Ref(1000L)
  let rt = @effect.Runtime::live(() => clock.val)
  let t = Turned::new(rt)
  let got : Ref[Json?] = Ref(None)
  let fiber = rt.fork(() => {
    @effect.sleep(50)
    let a = t.shell.call("storage.get", { "key": "k" })
    got.val = Some(a.json)
    @effect.sleep(200)
  })
  // (the fiber runs to its first sleep: due at 1050)
  assert_eq(t.turn(), Some(1050L))
  assert_eq(t.asked.length(), 0)
  // (a turn before it is due changes nothing)
  clock.val = 1020L
  assert_eq(t.turn(), Some(1050L))
  // (it asks, and waits for the answer: no timer)
  clock.val = 1050L
  assert_eq(t.turn(), None)
  assert_eq(t.asked.map(a => a.1), ["storage.get"])
  t.queue.push((t.asked[0].0, { "value": "v" }))
  assert_eq(got.val, None)
  // (the answer is taken at the next turn, and the fiber goes on to its second sleep)
  assert_eq(t.turn(), Some(1250L))
  assert_eq(got.val, Some({ "value": "v" }))
  assert_false(fiber.is_done())
  clock.val = 1250L
  assert_eq(t.turn(), None)
  assert_true(fiber.is_done())
  assert_true(rt.idle())
}

///|
test "turn takes in the same turn what is answered while it runs" {
  let clock = Ref(0L)
  let rt = @effect.Runtime::live(() => clock.val)
  let t = Turned::new(rt, at_once=true)
  let steps : Array[String] = []
  let fiber = rt.fork(() => {
    for op in ["a", "b", "c"] {
      steps.push(t.shell.call(op, {}).json.stringify())
    }
    // (a timer due at once, and what is forked, run in the same turn too)
    @effect.sleep(0)
    steps.push("slept")
    let _ = rt.fork(() => steps.push("forked"))
    @effect.sleep(30)
  })
  assert_eq(t.turn(), Some(30L))
  assert_eq(t.asked.map(a => a.1), ["a", "b", "c"])
  assert_eq(steps, [
    "{\"op\":\"a\"}", "{\"op\":\"b\"}", "{\"op\":\"c\"}", "slept", "forked",
  ])
  assert_true(t.queue.is_empty())
  clock.val = 30L
  assert_eq(t.turn(), None)
  assert_true(fiber.is_done())
}

///|
test "natively a tab's claim is held at once, and taking it over or letting it go tells nothing more" {
  let told : Array[TabState] = []
  let claim = claim_tab("one", s => told.push(s))
  assert_eq(told, [Held])
  claim.take_over()
  claim.release()
  claim.release()
  claim.take_over()
  let other : Array[TabState] = []
  ignore(claim_tab("one", s => other.push(s)))
  assert_eq(told, [Held])
  assert_eq(other, [Held])
}

///|
test "a shell's failure says the shell's words" {
  assert_eq(Show::to_string(ShellError("no such endpoint")), "no such endpoint")
}
