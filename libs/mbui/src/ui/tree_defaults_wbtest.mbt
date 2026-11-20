// Pure-tree defaults (app.mbt run_tree, tester.mbt Tester::tree): transitions_only=true by default so changes outside
// @view.transition settle immediately (Δt=0, at_rest), while changes inside @view.transition animate across frame rates.

///|
test "tree defaults: Tester::tree settles View::show and View::pick immediately outside @view.transition" {
  let flag = @signals.signal(false)
  let tab = @signals.signal(0)
  let made_show : Ref[@view.View?] = Ref(None)
  let t = Tester::tree(
    fn(root) {
      root.show(fn() { flag.get() }, fn(s) {
        made_show.val = Some(s)
        s.box(fn(b) { b.height(Is(Some(30.0))).ground(Is(0x3366CCFFL)) |> ignore }) |> ignore
      })
      root.pick(fn() { tab.get() }, fn(p, k) {
        p.box(fn(b) {
          b
          .height(Is(Some(if k == 0 { 24.0 } else { 40.0 })))
          .ground(Is(if k == 0 { 0x44AA44FFL } else { 0xCC6633FFL }))
          |> ignore
        })
        |> ignore
      })
    },
    w=300.0,
    h=200.0,
  )
  t.draw()
  assert_true(t.at_rest())
  // State changes outside @view.transition settle immediately on the next frame with no motion in flight.
  flag.set(true)
  tab.set(1)
  t.frame()
  assert_true(t.at_rest(), msg="changes outside @view.transition must settle at once")
  match made_show.val {
    Some(v) => assert_true(v.comes_end() < 0.0, msg="show should not start a come transition")
    None => @halt.saying("expected show child to be created")
  }
}

///|
test "tree defaults: changes inside @view.transition animate normally and settle after move_most_ms" {
  let flag = @signals.signal(false)
  let made_show : Ref[@view.View?] = Ref(None)
  let t = Tester::tree(
    fn(root) {
      root.show(fn() { flag.get() }, fn(s) {
        made_show.val = Some(s)
        s.box(fn(b) { b.height(Is(Some(30.0))).ground(Is(0x3366CCFFL)) |> ignore }) |> ignore
      })
      root.box(fn(line) { line.height(Is(Some(40.0))) |> ignore }) |> ignore
    },
    w=300.0,
    h=200.0,
  )
  t.draw()
  @view.transition(fn() { flag.set(true) })
  t.frame()
  match made_show.val {
    Some(v) => assert_true(v.comes_end() >= 0.0, msg="show inside @view.transition must animate")
    None => @halt.saying("expected show child to be created")
  }
  t.run_for(move_most_ms)
  assert_true(t.at_rest())
}

///|
test "tree defaults: Tester::tree(..., transitions_only=false) retains legacy automatic transitions" {
  let flag = @signals.signal(false)
  let made_show : Ref[@view.View?] = Ref(None)
  let t = Tester::tree(
    fn(root) {
      root.show(fn() { flag.get() }, fn(s) {
        made_show.val = Some(s)
        s.box(fn(b) { b.height(Is(Some(30.0))).ground(Is(0x3366CCFFL)) |> ignore }) |> ignore
      })
      root.box(fn(line) { line.height(Is(Some(40.0))) |> ignore }) |> ignore
    },
    w=300.0,
    h=200.0,
    transitions_only=false,
  )
  t.draw()
  flag.set(true)
  t.frame()
  match made_show.val {
    Some(v) => assert_true(v.comes_end() >= 0.0, msg="transitions_only=false should still animate outside @view.transition")
    None => @halt.saying("expected show child to be created")
  }
  t.run_for(move_most_ms)
  assert_true(t.at_rest())
}

///|
test "tree defaults: Tester::new defaults transitions_only=false and opts in with transitions_only=true" {
  let flag = @signals.signal(false)
  let made_show : Ref[@view.View?] = Ref(None)
  let t = Tester::new(
    fn(_c) { () },
    tree=fn(root) {
      root.show(fn() { flag.get() }, fn(s) {
        made_show.val = Some(s)
        s.box(fn(b) { b.height(Is(Some(30.0))).ground(Is(0x3366CCFFL)) |> ignore }) |> ignore
      })
      root.box(fn(line) { line.height(Is(Some(40.0))) |> ignore }) |> ignore
    },
    w=300.0,
    h=200.0,
    transitions_only=true,
  )
  t.draw()
  flag.set(true)
  t.frame()
  assert_true(t.at_rest(), msg="Tester::new(..., transitions_only=true) must settle outside @view.transition")
  match made_show.val {
    Some(v) => assert_true(v.comes_end() < 0.0, msg="show should not animate when transitions_only=true")
    None => @halt.saying("expected show child to be created")
  }
}
