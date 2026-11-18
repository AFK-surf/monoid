///|
let hold_first_step_ms : Double = 10.0

///|
let hold_first_answer_ms : Double = 80.0

///|
let hold_second_answer_ms : Double = 220.0

///|
let hold_short_ms : Double = 200.0

///|
let hold_long_ms : Double = 600.0

///|
fn hold_test_window(make : (@view.View) -> Unit) -> Tester {
  let t = Tester::new(fn(_) {  }, tree=make, time=-first_frame_ms)
  t.run_for(hold_first_step_ms)
  t
}

///|
#callsite(autofill(loc))
fn hold_test_loc(loc~ : SourceLoc) -> SourceLoc {
  loc
}

///|
test "HoldGate Tester: a cascade shares its first deadline and records one waterfall" {
  let gate_loc = hold_test_loc()
  let first_loc = hold_test_loc()
  let second_loc = hold_test_loc()
  let gate = @view.HoldGate::new(acknowledged=true, loc=gate_loc)
  let t = hold_test_window(fn(_) {  })
  let tree = view_tree().unwrap()
  let v = tree.root()
  let start = t.time()
  let first = @signals.signal(false)
  let second = @signals.signal(false)
  let done : Array[Int64] = []
  tree.event(start, fn() {
    gate.open_when(
      v,
      most=hold_short_ms,
      fn() {
        if !@view.hold_collecting() {
          @halt.saying("check should collect hold notes")
        }
        @view.hold_note(fn() { first.get() }, loc=first_loc)
        if first.get() {
          @view.hold_note(fn() { second.get() }, loc=second_loc)
        }
        true
      },
      fn() { done.push(v.cause_at().reinterpret_as_int64()) },
    )
    v.at_moment(start + hold_first_answer_ms, fn() { first.set(true) }) |> ignore
    v.at_moment(start + hold_second_answer_ms, fn() { second.set(true) }) |> ignore
  })
  t.draw()
  let next = start + hold_first_answer_ms / 2.0
  assert_true(t.frame_unasked(next))
  assert_true(gate.is_pending())
  assert_eq(t.waterfall_faults(), [])
  t.run_for(start + hold_first_answer_ms - t.time())
  assert_true(gate.is_pending())
  let faults = t.waterfall_faults()
  assert_eq(faults, [
    "[ASYNC_WATERFALL] Hold at \{@view.source_place(gate_loc)} started another async read at \{@view.source_place(second_loc)} " +
    "(\{hold_first_answer_ms}ms after \{@view.source_place(first_loc)}). " +
    "Fix: issue independent reads together up front before the first answer so they resolve in parallel.",
  ])
  t.run_for(start + hold_second_answer_ms - t.time())
  assert_eq(done, [(start + hold_short_ms).reinterpret_as_int64()])
  assert_false(gate.is_pending())
  assert_eq(t.waterfall_faults(), faults)
  assert_eq(t.hold_faults(), [])
  assert_true(t.at_rest(), msg=t.rest_why())
}

///|
test "HoldGate Tester: visible pending distinguishes silent and long holds at exact times" {
  for (with_feedback, deadline) in [(false, hold_short_ms), (true, hold_short_ms), (true, hold_long_ms)] {
    let gate = @view.HoldGate::new()
    let request_loc = hold_test_loc()
    let t = hold_test_window(fn(v) {
      if with_feedback {
        v.box(fn(box) {
          box.words(By(fn() { if gate.is_pending() { "Pending" } else { "Ready" } })) |> ignore
        }) |> ignore
      }
    })
    let tree = view_tree().unwrap()
    let v = tree.root()
    let start = t.time()
    let came : Array[Int64] = []
    tree.event(start, fn() {
      gate.open_when(v, most=deadline, fn() { false }, loc=request_loc, fn() {
        came.push(v.cause_at().reinterpret_as_int64())
      })
    })
    assert_true(gate.is_pending())
    let threshold = if with_feedback { @view.long_hold_ms } else { @view.silent_hold_ms }
    let fault_at = fn(elapsed : Double) {
      let place = @view.source_place(request_loc)
      if with_feedback {
        "[LONG_HOLD] Hold at \{place} waited \{elapsed}ms (>= \{threshold}ms). " +
        "Fix: cap local HoldGate most to 300ms or less and let remote waits enter View::bones immediately."
      } else {
        "[SILENT_HOLD] Hold at \{place} waited \{elapsed}ms (>= \{threshold}ms) with no UI acknowledgment. " +
        "Fix: bind HoldGate::is_pending() to a visible pending or disabled state, or acknowledge optimistic feedback via HoldGate::acknowledge()."
      }
    }
    let before = hold_first_answer_ms
    t.run_for(start + before - t.time())
    assert_true(gate.is_pending())
    assert_eq(t.hold_faults(), [])
    if deadline > threshold {
      t.run_for(start + threshold - t.time())
      assert_true(gate.is_pending())
      let pending = t.hold_faults()
      assert_eq(pending, [fault_at(threshold)])
      assert_eq(t.hold_faults(), pending)
    }
    t.run_for(start + deadline - t.time())
    assert_false(gate.is_pending())
    assert_eq(came, [(start + deadline).reinterpret_as_int64()])
    let settled = t.hold_faults()
    if !with_feedback || deadline == hold_long_ms {
      assert_eq(settled, [fault_at(deadline)])
    } else {
      assert_eq(settled, [])
    }
    assert_true(t.at_rest(), msg=t.rest_why())
  }
  let next = hold_test_window(fn(_) {  })
  assert_eq(next.hold_faults(), [])
  assert_eq(next.waterfall_faults(), [])
  assert_false(@view.hold_marks_left())
}

///|
test "HoldGate Tester: context loss, cancel, and owner disposal remove the timeline entry" {
  for cancellation in ["context", "manual", "owner"] {
    let gate = @view.HoldGate::new()
    let valid = @signals.signal(true)
    let mounted = @signals.signal(true)
    let ready = @signals.signal(false)
    let child : Ref[@view.View?] = Ref(None)
    let t = hold_test_window(fn(v) {
      v.show(at_once=true, fn() { mounted.get() }, fn(node) { child.val = Some(node) })
    })
    let tree = view_tree().unwrap()
    let node = child.val.unwrap()
    let start = t.time()
    let given_up = Ref(0)
    let passes = Ref(0)
    let checked = Ref(0)
    tree.event(start, fn() {
      gate.open_when(
        node,
        most=hold_long_ms,
        fn() {
          checked.val += 1
          ready.get()
        },
        while_still=fn() { valid.get() },
        on_give_up=fn() { given_up.val += 1 },
        fn() { passes.val += 1 },
      )
    })
    t.draw()
    assert_true(gate.is_pending())
    assert_eq(tree.due_count(), 1)
    let cancel_at = start + hold_first_answer_ms
    t.run_for(cancel_at - t.time())
    tree.event(cancel_at, fn() {
      match cancellation {
        "context" => valid.set(false)
        "manual" => gate.cancel()
        _ => mounted.set(false)
      }
    })
    assert_false(gate.is_pending())
    assert_eq(tree.due_count(), 0)
    assert_eq(given_up.val, 1)
    t.draw()
    assert_true(t.at_rest(), msg=t.rest_why())
    assert_true(t.frame_unasked(t.time() + hold_first_step_ms))
    let before = checked.val
    tree.event(cancel_at, fn() {
      ready.set(true)
      gate.cancel()
    })
    t.run_for(start + hold_long_ms - t.time())
    assert_eq(checked.val, before)
    assert_eq(given_up.val, 1)
    assert_eq(passes.val, 0)
    assert_eq(t.hold_faults(), [])
  }
}

///|
test "HoldGate Tester: a mounted pending binding acknowledges each round until it goes" {
  let gate = @view.HoldGate::new()
  let mounted = @signals.signal(true)
  let request_loc = hold_test_loc()
  let t = hold_test_window(fn(v) {
    v.show(at_once=true, fn() { mounted.get() }, fn(node) {
      node.words(By(fn() { if gate.is_pending() { "Pending" } else { "Ready" } })) |> ignore
    })
  })
  let tree = view_tree().unwrap()
  let v = tree.root()
  let came : Array[Int64] = []
  for round in 0..<3 {
    let start = t.time()
    tree.event(start, fn() {
      if round == 2 {
        mounted.set(false)
      }
    })
    tree.event(start, fn() {
      gate.open_when(v, most=hold_short_ms, fn() { false }, loc=request_loc, fn() {
        came.push(v.cause_at().reinterpret_as_int64())
      })
    })
    assert_true(gate.is_pending())
    t.run_for(hold_short_ms)
    assert_false(gate.is_pending())
    assert_eq(came[round], (start + hold_short_ms).reinterpret_as_int64())
    if round < 2 {
      assert_eq(t.hold_faults(), [])
    } else {
      assert_eq(t.hold_faults(), [
        "[SILENT_HOLD] Hold at \{@view.source_place(request_loc)} waited \{hold_short_ms}ms (>= \{@view.silent_hold_ms}ms) with no UI acknowledgment. " +
        "Fix: bind HoldGate::is_pending() to a visible pending or disabled state, or acknowledge optimistic feedback via HoldGate::acknowledge().",
      ])
    }
    assert_true(t.at_rest(), msg=t.rest_why())
  }
}

///|
test "HoldGate Tester: explicit feedback acknowledges one round unless set on the gate" {
  for always in [false, true] {
    let gate = @view.HoldGate::new(acknowledged=always)
    let t = hold_test_window(fn(_) {  })
    let tree = view_tree().unwrap()
    let v = tree.root()
    for round in 0..<3 {
      if round == 0 {
        gate.acknowledge()
      }
      let start = t.time()
      tree.event(start, fn() {
        gate.open_when(v, most=hold_short_ms, fn() { false }, fn() {  })
        if round == 1 {
          gate.acknowledge()
        }
      })
      t.run_for(hold_short_ms)
      assert_false(gate.is_pending())
      assert_eq(t.hold_faults().length(), if round == 2 && !always { 1 } else { 0 })
    }
  }
}
///|
test "Tester records box reads and resets diagnostics between runs" {
  let snapshot = @signals.signal(1)
  let made = hold_test_loc()
  let t = hold_test_window(fn(v) {
    v.box(loc=made, fn(_) { snapshot.get() |> ignore }) |> ignore
  })
  let faults = t.untracked_read_faults()
  assert_eq(faults.length(), 1)
  assert_true(faults[0].has_prefix("[STRICT_READ_UNTRACKED]"), msg=faults[0])
  assert_true(faults[0].contains(@view.source_place(made)), msg=faults[0])
  let tree = view_tree().unwrap()
  let next = hold_test_window(fn(_) {  })
  assert_eq(next.untracked_read_faults(), [])
  assert_eq(tree.untracked_read_faults(), [])
  assert_false(@view.untracked_read_marks_left())
}

///|
test "Tester detects list and selection broadcasts while keyed rows stay below the threshold" {
  for keyed in [false, true] {
    let items = @signals.signal([(0, "a"), (1, "b"), (2, "c"), (3, "d")])
    let selection = @signals.signal(Some(0))
    let t = hold_test_window(fn(v) {
      let item = if keyed {
        let rows = v.keyed_by(fn() { items.get() }, fn(row) { row.0 })
        fn(i) { rows.get(i).unwrap().1 }
      } else {
        fn(i) { items.get()[i].1 }
      }
      let selected = if keyed {
        v.selected(fn() { selection.get() })
      } else {
        fn(i) { selection.get() == Some(i) }
      }
      for i in 0..<4 {
        v.box(fn(row) {
          row.words(By(fn() { item(i) })) |> ignore
          row.box(fn(mark) {
            mark.words(By(fn() { if selected(i) { "Selected \{i}" } else { "" } })) |> ignore
          }) |> ignore
        }) |> ignore
      }
    })
    let list_write = hold_test_loc()
    let selection_write = hold_test_loc()
    t.set_fanout_limit(4)
    items.set([(0, "a"), (1, "b"), (2, "changed"), (3, "d")], loc=list_write)
    selection.set(Some(2), loc=selection_write)
    let faults = t.fanout_faults()
    t.set_fanout_limit(0)
    assert_eq(t.fanout_faults(), [])
    t.draw()
    assert_true(t.find("changed") is Some(_))
    assert_true(t.find("Selected 2") is Some(_))
    assert_true(t.find("Selected 0") is None)
    if keyed {
      assert_eq(faults, [])
    } else {
      assert_eq(faults.length(), 2, msg="\{Repr(faults)}")
      for i, loc in [list_write, selection_write] {
        let fault = faults[i]
        assert_true(
          fault.has_prefix("[FAN_OUT] Signal write at \{@view.source_place(loc)} notified 4 subscribers (>= 4). Fix:"),
          msg=fault,
        )
      }
    }
    t.set_fanout_limit(1)
    items.set([(0, "a"), (1, "b"), (2, "c"), (3, "d")])
    assert_false(t.fanout_faults().is_empty())
    let next = hold_test_window(fn(_) {  })
    assert_eq(next.fanout_faults(), [])
    assert_eq(@signals.fanout_limit.val, 0)
    assert_true(@signals.on_fanout.val is None)
  }
}
