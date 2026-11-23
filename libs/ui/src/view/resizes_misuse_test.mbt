// A height said to make its way (View::resizes) where it never can (a node grown, over what holds it, laid out by a
// row it makes no way along) is a fault, said with the line that said it: before, it was dropped without a word and
// the height jumped where the page meant it to go (#6532: a grown node's resizes, nothing on a device). Where it can,
// none: a node in its turn down a column, said before the tree was laid out, or with motion reduced.

///|
/// `f` run as an app's run on a host runs (a fault told, not stopping the run); what was told said back.
fn resizes_faults(f : () -> Unit) -> Array[String] {
  let told : Array[String] = []
  @view.faults_stop.val = false
  @view.fault_told.val = Some(fn(said) { told.push(said) })
  f()
  @view.faults_stop.val = true
  @view.fault_told.val = None
  told
}

///|
/// A column of a node in its turn (`turn`), a grown one (`grown`) and a row holding one (`in_row`), each 40 tall, the
/// tree laid out; `said` run in an event at 100 ms on them.
fn resizes_said_on(said : (@view.View, @view.View, @view.View) -> Unit) -> Array[String] {
  resizes_faults(fn() {
    let turn : Ref[@view.View?] = Ref(None)
    let grown : Ref[@view.View?] = Ref(None)
    let in_row : Ref[@view.View?] = Ref(None)
    let t = @view.Tree::new(sources=true, fn(root) {
      root.box(fn(b) {
        b.height(Is(Some(40.0))) |> ignore
        turn.val = Some(b)
      })
      |> ignore
      root.box(fn(b) {
        b.grow(Is(1.0)) |> ignore
        grown.val = Some(b)
      })
      |> ignore
      root.box(fn(r) {
        r.row(Is(true)).height(Is(Some(40.0))) |> ignore
        r.box(fn(b) {
          b.width(Is(Some(40.0))).height(Is(Some(40.0))) |> ignore
          in_row.val = Some(b)
        })
        |> ignore
      })
      |> ignore
    })
    t.frame(390.0, 844.0) |> ignore
    t.event(100.0, fn() { said(turn.val.unwrap(), grown.val.unwrap(), in_row.val.unwrap()) })
    t.at(100.0)
    t.frame(390.0, 844.0) |> ignore
  })
}

///|
test "View::resizes on a grown node, or one a row lays out: a fault, said with the line that said it and where the node was made" {
  let told = resizes_said_on(fn(_turn, grown, in_row) {
    grown.resizes() |> ignore
    in_row.resizes() |> ignore
  })
  assert_eq(told.length(), 2, msg="\{Repr(told)}")
  assert_true(told[0].contains("it is grown"), msg=told[0])
  assert_true(told[1].contains("what lays it out is a row"), msg=told[1])
  for said in told {
    assert_true(said.contains("View::resizes said at ui/src/view/resizes_misuse_test.mbt:"), msg=said)
    assert_true(said.contains("the node made at ui/src/view/resizes_misuse_test.mbt:"), msg=said)
  }
}

///|
test "View::resizes where the height can make its way: no fault, in its turn down a column, before the tree is laid out, or its height the same" {
  let told = resizes_said_on(fn(turn, _grown, _in_row) {
    turn.resizes() |> ignore
    turn.height(Is(Some(80.0))) |> ignore
    turn.resizes(foot=true) |> ignore
  })
  assert_eq(told, [])
  // (said as the tree is first made: nothing laid out yet, nothing known of where it goes)
  let first = resizes_faults(fn() {
    let t = @view.Tree::new(fn(root) {
      root.box(fn(b) { b.grow(Is(1.0)).resizes() |> ignore }) |> ignore
    })
    t.frame(390.0, 844.0) |> ignore
  })
  assert_eq(first, [])
}
