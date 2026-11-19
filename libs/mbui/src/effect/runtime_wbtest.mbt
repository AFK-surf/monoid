///|
/// The last seq an Int holds: what is set next is set there.
let last_seq : Int = 2147483647

///|
/// A frame's time, after the runtime's start.
let frame_ms : Int64 = 16L

///|
/// A task made ready between frames with the last seq an Int holds, no timer set: the next frame runs it, once, and
/// nothing is left (no seq stands for "no timer", whatever seq a task has).
test "a task made ready between frames at the last seq, no timer: the frame runs it once" {
  let rt = Runtime::new()
  rt.seq = last_seq - 1
  let ran : Array[Int64] = []
  rt.fork(fn() { ran.push(now()) }) |> ignore
  // (said before the frame: a run killed after it hung in the frame, not in building)
  println("seq edge: the frame starts")
  rt.frame(frame_ms)
  assert_eq(ran, [0L])
  assert_true(rt.idle())
}

///|
/// How a fiber ended, said.
fn[X : Show] ended(f : Fiber[X]) -> String {
  match f.poll() {
    None => "running"
    Some(Succeeded(x)) => "ok \{x}"
    Some(Failed(e)) => "failed \{e}"
    Some(Interrupted) => "interrupted"
  }
}

///|
/// A quiet fiber's failure is only its joiner's: `wait` and `join` see it, `on_defect` never does; one still running
/// is interrupted as its scope closes, and nothing is left.
test "fork_quiet: a failure is left to join and wait, never on_defect" {
  let rt = Runtime::new()
  let s = rt.scope()
  let bad : Fiber[Int] = s.fork_quiet(
    () => raise IoError("broken"),
    name="bad",
  )
  let hung : Fiber[Int] = s.fork_quiet(() => never(), name="hung")
  let waited = rt.fork(async fn() {
    match bad.wait() {
      Failed(IoError(m)) => "wait failed: \{m}"
      _ => "wait: other"
    }
  })
  let joined = rt.fork(async fn() {
    let got = bad.join() catch {
      IoError(m) => return "join raised: \{m}"
      e => return "join raised other: \{e}"
    }
    "join returned \{got}"
  })
  ignore(rt.run_ready())
  assert_eq(rt.defects, [])
  assert_true(bad.poll() is Some(Failed(IoError("broken"))))
  assert_eq(ended(waited), "ok wait failed: broken")
  assert_eq(ended(joined), "ok join raised: broken")
  assert_eq(ended(hung), "running")
  s.close_now()
  ignore(rt.run_ready())
  assert_eq(ended(hung), "interrupted")
  assert_eq(s.running(), 0)
  rt.shutdown()
  ignore(rt.run_ready())
  assert_eq(rt.defects, [])
  assert_eq(rt.holding(), (0, 0, 0, 0, 0, 0))
}

///|
/// The root's quiet fork tells no one either.
test "Runtime::fork_quiet: a failure on the root scope is not a defect" {
  let rt = Runtime::new()
  let bad : Fiber[Unit] = rt.fork_quiet(() => raise IoError("broken"))
  ignore(rt.run_ready())
  assert_eq(rt.defects, [])
  assert_true(bad.poll() is Some(Failed(IoError("broken"))))
  // the plain fork, beside it, still tells
  let told : Fiber[Unit] = rt.fork(() => raise IoError("told"))
  ignore(rt.run_ready())
  assert_true(told.poll() is Some(Failed(_)))
  assert_eq(rt.defects.length(), 1)
  rt.shutdown()
  ignore(rt.run_ready())
  assert_eq(rt.holding(), (0, 0, 0, 0, 0, 0))
}

///|
/// A daemon's failure goes to its `on_error`, once; it ends as having done its work.
test "fork_daemon: a failure goes to on_error, never on_defect" {
  let rt = Runtime::new()
  let errors : Array[String] = []
  // how long the pump works before it breaks
  let works = 10
  let d = rt.fork_daemon(
    "pump",
    async fn() {
      sleep(works)
      raise IoError("broken")
    },
    on_error=e => errors.push(e.to_string()),
  )
  rt.advance(works)
  assert_eq(errors.length(), 1)
  assert_eq(rt.defects, [])
  assert_eq(ended(d), "ok ()")
  rt.shutdown()
  ignore(rt.run_ready())
  assert_eq(rt.holding(), (0, 0, 0, 0, 0, 0))
}

///|
/// Interrupted where it sleeps, by `interrupt_and_wait` or by its scope closing, a daemon ends interrupted and its
/// `on_error` is not called.
test "fork_daemon: interrupted as it sleeps, it ends interrupted without on_error" {
  let rt = Runtime::new()
  let errors : Array[String] = []
  let s = rt.scope()
  // how long each daemon sleeps, and when (well before) it is stopped
  let asleep = 1000
  let stopped_at = 10
  let by_hand = s.fork_daemon("by hand", () => sleep(asleep), on_error=e => {
    errors.push(e.to_string())
  })
  let by_close = s.fork_daemon("by close", () => sleep(asleep), on_error=e => {
    errors.push(e.to_string())
  })
  rt.advance(stopped_at)
  let stopper = rt.fork(() => by_hand.interrupt_and_wait() is Interrupted)
  ignore(rt.run_ready())
  assert_eq(ended(stopper), "ok true")
  assert_eq(ended(by_hand), "interrupted")
  assert_eq(ended(by_close), "running")
  s.close_now()
  ignore(rt.run_ready())
  assert_eq(ended(by_close), "interrupted")
  assert_eq(errors, [])
  assert_eq(rt.defects, [])
  rt.shutdown()
  ignore(rt.run_ready())
  assert_eq(rt.holding(), (0, 0, 0, 0, 0, 0))
}

///|
/// A daemon joining a fiber of its scope as the scope closes ends interrupted, `on_error` not called, under every
/// order the seeds give: whether its own cut wakes it, or (shielded, so only the child's end wakes it) the child's
/// `Interrupt` comes out of the join while it was asked to stop itself. A child interrupted by someone else, the
/// daemon not, is a failure like any other: `on_error` hears `Interrupt`.
test "fork_daemon: closed while it joins a child, it ends interrupted without on_error, over seeds" {
  for_seeds(count=30, seed => {
    let rt = Runtime::new(seed~)
    // how long the daemons have joined before their scope closes or their child is cut
    let joining = 5
    let errors : Array[String] = []
    let s = rt.scope()
    let child : Fiber[Unit] = s.fork_quiet(() => never(), name="child")
    let plain = s.fork_daemon("plain", () => child.join(), on_error=e => {
      errors.push(e.to_string())
    })
    let shielded_child : Fiber[Unit] = s.fork_quiet(
      () => never(),
      name="shielded child",
    )
    let shielded = s.fork_daemon(
      "shielded",
      () => uninterruptible(() => shielded_child.join()),
      on_error=e => errors.push(e.to_string()),
    )
    rt.advance(joining)
    s.close_now()
    ignore(rt.run_ready())
    assert_eq(ended(child), "interrupted")
    assert_eq(ended(shielded_child), "interrupted")
    assert_eq(ended(plain), "interrupted")
    assert_eq(ended(shielded), "interrupted")
    assert_eq(errors, [])
    assert_eq(rt.defects, [])
    // the daemon not asked to stop: its child's interruption is its failure
    let other = rt.scope()
    let cut : Fiber[Unit] = other.fork_quiet(() => never(), name="cut")
    let kept = rt.fork_daemon("kept", () => cut.join(), on_error=e => {
      errors.push(if e is Interrupt { "Interrupt" } else { e.to_string() })
    })
    rt.advance(joining)
    cut.interrupt()
    ignore(rt.run_ready())
    assert_eq(errors, ["Interrupt"])
    assert_eq(ended(kept), "ok ()")
    assert_eq(rt.defects, [])
    other.close_now()
    rt.shutdown()
    ignore(rt.run_ready())
    assert_eq(rt.holding(), (0, 0, 0, 0, 0, 0))
  })
}
