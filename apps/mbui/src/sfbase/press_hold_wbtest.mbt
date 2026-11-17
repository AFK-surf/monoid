///|
let press_hold_budget_ms : Double = 180.0

///|
let press_hold_answer_ms : Double = 63.0

///|
test "Source::topic holds for local data and immediately opens on a station wait" {
  for staged in [false, true] {
    for remote in [false, true] {
      let ready = @signals.signal(false)
      let base = made_source(topic=fn(_, _) { if ready.get() { Some(Json::string("ready")) } else { None } })
      let src : Source = { ..base, waits: fn(_, _) { remote } }
      let t = @ui.Tester::new(fn(_) {  }, tree=fn(_) {  })
      let tree = @ui.view_tree().unwrap()
      let root = tree.root()
      let start = t.time()
      let opened : Array[Int64] = []
      let open = fn() { opened.push(root.cause_at().reinterpret_as_int64()) }
      let gate = @view.HoldGate::new(acknowledged=true)
      tree.event(start, fn() {
        if staged {
          gate.collect(fn() { src.topic("example", Map([])) |> ignore })
          gate.seal(root)
          gate.go(root, most=press_hold_budget_ms, open)
        } else {
          gate.open_when(root, most=press_hold_budget_ms, fn() {
            src.topic("example", Map([])) |> ignore
            true
          }, open)
        }
        root.at_moment(start + press_hold_answer_ms, fn() { ready.set(true) }) |> ignore
      })
      if remote {
        assert_false(gate.is_pending())
        assert_eq(opened, [start.reinterpret_as_int64()])
      } else {
        assert_true(gate.is_pending())
        assert_eq(opened, [])
      }
      t.run_for(press_hold_budget_ms)
      let opened_at = if remote { start } else { start + press_hold_answer_ms }
      assert_eq(opened, [opened_at.reinterpret_as_int64()])
      assert_false(gate.is_pending())
      assert_eq(tree.due_count(), 0)
    }
  }
}

///|
test "bounded press waits settle at the answer or deadline and release at most once" {
  for reason in ["answer", "deadline", "end", "give up", "check", "context changed"] {
    let t = @ui.Tester::new(fn(_) {  }, tree=fn(_) {  })
    let tree = @ui.view_tree().unwrap()
    let root = tree.root()
    let start = t.time()
    let answer_at = start + press_hold_answer_ms
    let ready = @signals.signal(false)
    let checked = Ref(false)
    let opened : Array[Int64] = []
    let released = Ref(0)
    let wait : Ref[PressWait?] = Ref(None)
    tree.event(start, fn() {
      wait.val = Some(press_wait(
        fn() { ready.get() || checked.val },
        fn() { opened.push(root.cause_at().reinterpret_as_int64()) },
        let_go=fn() { released.val += 1 },
        most=press_hold_budget_ms,
        holds=false,
      ))
    })
    let press = wait.val.unwrap()
    assert_true(press.waiting())
    assert_eq(tree.due_count(), 1)
    root.at_moment(answer_at, fn() {
      match reason {
        "answer" => ready.set(true)
        "end" => press.end()
        "give up" => press.give_up()
        "check" => {
          checked.val = true
          press.check()
        }
        "context changed" => {
          @sf.menu([Some(@sf.menu_item_of("Other menu", fn() {  }))], from=@sf.at_point(20.0, 20.0))
        }
        _ => ()
      }
    }) |> ignore
    t.run_for(press_hold_budget_ms)
    let wanted = match reason {
      "answer" | "check" => [answer_at.reinterpret_as_int64()]
      "deadline" => [(start + press_hold_budget_ms).reinterpret_as_int64()]
      _ => []
    }
    assert_false(press.waiting())
    assert_eq(tree.due_count(), 0)
    assert_eq(opened, wanted)
    let released_once = if reason == "give up" || reason == "context changed" { 1 } else { 0 }
    assert_eq(released.val, released_once)
    tree.event(t.time(), fn() {
      ready.set(true)
      press.give_up()
      press.check()
    })
    assert_eq(opened, wanted)
    assert_eq(released.val, released_once)
  }
}
