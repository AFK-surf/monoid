// What comes and goes said once (presence_in, presence_look) and a pick whose one before goes out its own way
// before the next is made (View::pick's `leave_of`), as a host draws them.

///|
/// How long what goes takes in these tests.
let presence_test_ms : Double = 200.0

///|
/// How opaque the words `w` are drawn (0 where none are).
fn presence_seen(t : @ui.Tester, w : String) -> Double {
  match t.words().iter().find_first(fn(d) { d.0 == w }) {
    Some(d) => d.5
    None => 0.0
  }
}

///|
test "presence_in: in from its making, out as what holds it lets it go, back in from where it is shown again on its way out" {
  let open = @signals.signal(false)
  let t = @ui.Tester::new(fn(_c) {  })
  @ui.set_view_app(fn(root) {
    root.show(leave=presence_test_ms, fn() { open.get() }, fn(s) {
      let shown = presence_in(s, tween(presence_test_ms, ease=Out))
      s.alpha(@view.By(shown)).words(@view.Is("来")) |> ignore
    })
  })
  t.draw()
  open.set(true)
  t.run_for(presence_test_ms / 2.0)
  let half_in = presence_seen(t, "来")
  assert_true(half_in > 0.0 && half_in < 1.0, msg="half way in: \{half_in}")
  t.run_for(presence_test_ms)
  assert_eq(presence_seen(t, "来"), 1.0)
  open.set(false)
  t.run_for(presence_test_ms / 2.0)
  let half_out = presence_seen(t, "来")
  assert_true(half_out > 0.0 && half_out < 1.0, msg="half way out: \{half_out}")
  // (shown again on its way out: back in from there, the same node)
  open.set(true)
  t.run_for(presence_test_ms)
  assert_eq(presence_seen(t, "来"), 1.0)
  open.set(false)
  t.run_for(presence_test_ms * 2.0)
  assert_eq(presence_seen(t, "来"), 0.0)
}

///|
test "presence_look: a look that scales or moves says it carries what it holds while it goes (Tree::on_way_at); a fade says none" {
  let t = @ui.Tester::new(fn(_c) {  })
  let moved : Ref[@view.View?] = Ref(None)
  let faded : Ref[@view.View?] = Ref(None)
  @ui.set_view_app(fn(root) {
    root.box(fn(a) {
      moved.val = Some(a)
      let look = presence_look(
        a,
        trans(fade=0.0, scale=0.98, dy=6.0, spec=tween(presence_test_ms, ease=Out)),
      )
      a.alpha(@view.By(fn() { look().alpha })).scale(@view.By(fn() { look().sx })).words(@view.Is("移")) |> ignore
    })
    |> ignore
    root.box(fn(b) {
      faded.val = Some(b)
      b.alpha(@view.By(presence_in(b, tween(presence_test_ms, ease=Out)))).words(@view.Is("淡")) |> ignore
    })
    |> ignore
  })
  t.draw()
  let a = moved.val.unwrap()
  let b = faded.val.unwrap()
  assert_eq((a.tree.on_way_at(a.at, t.time()), b.tree.on_way_at(b.at, t.time())), (true, false))
  t.run_for(presence_test_ms * 2.0)
  assert_eq(a.tree.on_way_at(a.at, t.time()), false)
}

///|
test "pick leave_of: what it showed goes out its own way before what it shows now is made, never both seen; asked back meanwhile, the same node back" {
  let which = @signals.signal("甲")
  let made : Array[String] = []
  let t = @ui.Tester::new(fn(_c) {  })
  @ui.set_view_app(fn(root) {
    root.pick(
      leave_of=fn(was, now) { if was == "甲" && now == "乙" { presence_test_ms } else { 0.0 } },
      fn() { which.get() },
      fn(v, k) {
        made.push(k)
        v.alpha(@view.By(presence_in(v, tween(presence_test_ms, ease=Out)))).words(@view.Is(k)) |> ignore
      },
    )
  })
  t.run_for(presence_test_ms * 2.0)
  which.set("乙")
  t.run_for(presence_test_ms / 2.0)
  let a = presence_seen(t, "甲")
  assert_true(a > 0.0 && a < 1.0, msg="甲 half way out: \{a}")
  assert_eq(presence_seen(t, "乙"), 0.0)
  // (asked back meanwhile: 甲 back from where it is, 乙 never made)
  which.set("甲")
  t.run_for(presence_test_ms * 2.0)
  assert_eq((presence_seen(t, "甲"), made), (1.0, ["甲"]))
  // (and on: 乙 made once 甲 is gone, the one before let go)
  which.set("乙")
  t.run_for(presence_test_ms)
  t.run_for(presence_test_ms)
  assert_eq((presence_seen(t, "甲"), presence_seen(t, "乙"), made), (0.0, 1.0, ["甲", "乙"]))
}
