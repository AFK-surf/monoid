///|
let hold_start_ms : Double = 10.0

///|
let hold_budget_ms : Double = 240.0

///|
let hold_answer_ms : Double = 73.0

///|
let hold_zero_ms : Double = 0.0

///|
test "HoldGate: sealed collection and zero budgets pass synchronously" {
  let tree = @view.Tree::new(fn(_) {  })
  let v = tree.root()
  let gate = @view.HoldGate::new()
  let done : Array[Double] = []
  let other = @view.HoldGate::new()
  // A read that only waits on the network is ready for the transition. Its view can show bones.
  let remote_wait = @signals.signal(true)
  let collecting : Array[Bool] = []
  let checkpoints : Array[(Int, Bool, Int)] = []
  tree.event(hold_start_ms, fn() {
    gate.go(v, most=hold_budget_ms, fn() { done.push(v.cause_at()) })
    checkpoints.push((done.length(), gate.is_pending(), tree.due_count()))
    gate.collect(fn() {
      collecting.push(@view.hold_collecting())
      other.collect(fn() { @view.hold_note(fn() { false }) })
      @view.hold_note(fn() { remote_wait.get() })
    })
    collecting.push(@view.hold_collecting())
    gate.seal(v)
    checkpoints.push((done.length(), gate.is_pending(), tree.due_count()))
    gate.open_when(v, most=hold_zero_ms, fn() { false }, fn() { done.push(v.cause_at()) })
    checkpoints.push((done.length(), gate.is_pending(), tree.due_count()))
  })
  assert_eq(collecting, [true, false])
  assert_eq(checkpoints, [(0, false, 0), (1, false, 0), (2, false, 0)])
  assert_eq(done, [hold_start_ms, hold_start_ms])
  assert_false(@view.hold_marks_left())
  tree.dispose()
}

///|
test "HoldGate: early readiness and deadline each release exactly once" {
  for answered in [true, false] {
    let tree = @view.Tree::new(fn(_) {  })
    let v = tree.root()
    let ready = @signals.signal(false)
    let gate = @view.HoldGate::new()
    let done : Array[Double] = []
    let deadline = hold_start_ms + hold_budget_ms
    gate.collect(fn() { @view.hold_note(fn() { ready.get() }) })
    gate.seal(v)
    tree.event(hold_start_ms, fn() {
      gate.go(v, most=hold_budget_ms, fn() { done.push(v.cause_at()) })
    })
    assert_true(gate.is_pending())
    assert_eq(tree.due_count(), 1)
    if answered {
      tree.event(hold_answer_ms, fn() { ready.set(true) })
      assert_eq(done, [hold_answer_ms])
      assert_eq(tree.due_count(), 0)
    }
    tree.advance(deadline)
    assert_eq(done, [if answered { hold_answer_ms } else { deadline }])
    assert_false(gate.is_pending())
    assert_eq(tree.due_count(), 0)
    tree.event(deadline + hold_answer_ms, fn() { ready.set(true) })
    assert_eq(done.length(), 1)
    tree.dispose()
  }
}

///|
test "HoldGate: stale and cancelled queued requests give up exactly once" {
  let tree = @view.Tree::new(fn(_) {  })
  let v = tree.root()
  let gate = @view.HoldGate::new()
  let given_up = Ref(0)
  let done = Ref(0)
  let give_up = fn() { given_up.val += 1 }
  let go = fn() { done.val += 1 }
  tree.event(hold_start_ms, fn() {
    gate.go(v, most=hold_budget_ms, on_give_up=give_up, go)
    gate.stop()
    gate.seal(v)
    gate.open_when(v, most=hold_budget_ms, fn() { true }, while_still=fn() { false }, on_give_up=give_up, go)
  })
  assert_eq(given_up.val, 2)
  assert_eq(done.val, 0)
  assert_eq(tree.due_count(), 0)
  assert_false(gate.is_pending())
  tree.dispose()
}

///|
test "HoldGate: another collection takes its new owner even when go precedes seal" {
  for go_first in [false, true] {
    let replace = @signals.signal(false)
    let first : Ref[@view.View?] = Ref(None)
    let second : Ref[@view.View?] = Ref(None)
    let tree = @view.Tree::new(fn(root) {
      root.show(at_once=true, fn() { !replace.get() }, fn(v) { first.val = Some(v) })
      root.show(at_once=true, fn() { replace.get() }, fn(v) { second.val = Some(v) })
    })
    let v1 = first.val.unwrap()
    let gate = @view.HoldGate::new()
    let done : Array[Double] = []
    tree.event(hold_start_ms, fn() {
      gate.collect(fn() { @view.hold_note(fn() { true }) })
      gate.seal(v1)
      gate.go(v1, most=hold_budget_ms, fn() { done.push(v1.cause_at()) })
    })
    assert_eq(done, [hold_start_ms])
    let next = hold_start_ms + hold_answer_ms
    tree.event(next, fn() { replace.set(true) })
    assert_false(v1.alive())

    let v2 = second.val.unwrap()
    let ready = @signals.signal(false)
    let go = fn() { done.push(v2.cause_at()) }
    let before_seal = Ref(-1)
    tree.event(next, fn() {
      gate.collect(fn() {
        gate.collect(fn() { @view.hold_note(fn() { ready.get() }) })
      })
      if go_first {
        gate.go(v2, most=hold_budget_ms, go)
      }
      before_seal.val = tree.due_count()
      gate.seal(v2)
      if !go_first {
        gate.go(v2, most=hold_budget_ms, go)
      }
    })
    assert_eq(before_seal.val, 0)
    assert_true(gate.is_pending())
    assert_eq(tree.due_count(), 1)
    let answered = next + hold_answer_ms
    tree.event(answered, fn() { ready.set(true) })
    assert_eq(done, [hold_start_ms, answered])
    assert_false(gate.is_pending())
    assert_eq(tree.due_count(), 0)
    tree.dispose()
  }
}

///|
test "HoldGate: once passes straight through after readiness or timeout, never after stop" {
  for answer_first in [true, false] {
    let tree = @view.Tree::new(fn(_) {  })
    let v = tree.root()
    let gate = @view.HoldGate::new(once=true)
    let ready = @signals.signal(false)
    let done : Array[Double] = []
    let give_ups = Ref(0)
    let go = fn() { done.push(v.cause_at()) }
    let begin = fn() {
      gate.collect(fn() { @view.hold_note(fn() { ready.get() }) })
      gate.seal(v)
      gate.go(v, most=hold_budget_ms, on_give_up=fn() { give_ups.val += 1 }, go)
    }
    tree.event(hold_start_ms, begin)
    assert_true(gate.is_pending())
    gate.stop()
    assert_eq(give_ups.val, 1)
    assert_eq(done, [])
    assert_eq(tree.due_count(), 0)

    let next = hold_start_ms + hold_answer_ms
    tree.event(next, begin)
    assert_true(gate.is_pending())
    assert_eq(done, [])
    let release = next + (if answer_first { hold_answer_ms } else { hold_budget_ms })
    if answer_first {
      tree.event(release, fn() { ready.set(true) })
    } else {
      tree.advance(release)
    }
    assert_eq(done, [release])
    assert_false(gate.is_pending())
    assert_eq(tree.due_count(), 0)

    let after = release + hold_answer_ms
    let synchronous = Ref(false)
    let reads = Ref(0)
    tree.event(after, fn() {
      gate.collect(fn() {
        @view.hold_note(fn() {
          reads.val += 1
          false
        })
      })
      // This gate has already passed. Go before seal without keeping a request for later.
      gate.go(v, most=hold_budget_ms, go)
      synchronous.val = done.length() == 2 && !gate.is_pending() && tree.due_count() == 0
      gate.seal(v)
    })
    assert_true(synchronous.val)
    assert_eq(reads.val, 0)
    assert_eq(done, [release, after])
    assert_eq(give_ups.val, 1)
    tree.dispose()
  }
}

///|
test "HoldGate: stop preserves sealed reads for the next go" {
  for answered in [true, false] {
    let tree = @view.Tree::new(fn(_) {  })
    let v = tree.root()
    let gate = @view.HoldGate::new(once=true)
    let ready = @signals.signal(false)
    let done : Array[Double] = []
    let go = fn() { done.push(v.cause_at()) }
    tree.event(hold_start_ms, fn() {
      gate.collect(fn() { @view.hold_note(fn() { ready.get() }) })
      gate.seal(v)
      gate.go(v, most=hold_budget_ms, go)
    })
    assert_true(gate.is_pending())
    tree.event(hold_start_ms + hold_answer_ms, fn() { gate.stop(give_up=false) })
    assert_false(gate.is_pending())
    assert_eq(tree.due_count(), 0)
    assert_eq(done, [])

    let reopened = hold_start_ms + 2.0 * hold_answer_ms
    tree.event(reopened, fn() { gate.go(v, most=hold_budget_ms, go) })
    assert_true(gate.is_pending())
    assert_eq(done, [])
    let released = reopened + (if answered { hold_answer_ms } else { hold_budget_ms })
    if answered {
      tree.event(released, fn() { ready.set(true) })
    } else {
      tree.advance(hold_start_ms + hold_budget_ms)
      assert_eq(done, [])
      tree.advance(released)
    }
    assert_eq(done, [released])
    assert_false(gate.is_pending())
    assert_eq(tree.due_count(), 0)

    let opened_again = released + hold_answer_ms
    let synchronous = Ref(false)
    tree.event(opened_again, fn() {
      ready.set(false)
      gate.go(v, most=hold_budget_ms, go)
      synchronous.val = done == [released, opened_again]
    })
    assert_true(synchronous.val)
    tree.dispose()
  }
}
