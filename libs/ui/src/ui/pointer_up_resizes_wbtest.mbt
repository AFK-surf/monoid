///|
test "pointer up triggering property + reacts(resizes) + show does not snap frame 0 via mid-batch view_pointed" {
  let on = @signals.signal(false, same=fn(a, b) { a == b })
  let room_ref : Ref[@view.View?] = Ref(None)
  let t = Tester::tree(
    fn(root) {
      root.box(fn(col) {
        col.width(Is(Some(300.0))) |> ignore
        col.box(fn(btn) {
          btn
          .width(Is(Some(100.0)))
          .height(Is(Some(44.0)))
          .shrink(Is(0.0))
          .words(Is("触发"))
          .on_press(fn() { @view.transition(within=root, fn() { on.set(true) }) })
          |> ignore
        })
        |> ignore
        col.box(fn(room) {
          room_ref.val = Some(room)
          room.shrink(Is(0.0)) |> ignore
          room.box(fn(inner) {
            inner
            .padding(By(fn() { if on.get() { (0.0, 0.0, 0.0, 10.0) } else { (0.0, 0.0, 0.0, 0.0) } }))
            |> ignore
            inner.show(fn() { on.get() }, fn(item) {
              item.height(Is(Some(60.0))).shrink(Is(0.0)).words(Is("项")) |> ignore
            })
          })
          |> ignore
        })
        |> ignore
        col.box(fn(b) { b.height(Is(Some(20.0))).shrink(Is(0.0)).words(Is("下")) |> ignore }) |> ignore
      })
      |> ignore
      root.reacts(
        fn() { on.get() },
        fn(v) {
          if v {
            match room_ref.val {
              Some(room) => room.resizes(uncut=true) |> ignore
              None => ()
            }
          }
        },
        at_start=false,
      )
    },
    w=400.0,
    h=300.0,
    pointing=Mouse,
    native=Mouse,
  )
  t.run_for(move_most_ms)
  let room = room_ref.val.unwrap()
  assert_true(room.placed_now().3.abs() < 0.01, msg="initial room height should be 0.0, got \{room.placed_now().3}")
  t.tap(50.0, 22.0)
  // Frame 0 (tap frame): room height must remain 0.0, never snapping to 10.0 from mid-batch view_pointed
  let h0 = room.placed_now().3
  assert_true(h0.abs() < 0.01, msg="frame-0 room height snapped to \{h0} instead of 0.0")
  // Mid-flight samples must smoothly progress through (0, 70) without reversing
  let step = move_most_ms / 8.0
  t.run_for(step)
  let h1 = room.placed_now().3
  assert_true(h1 > 0.5 && h1 < 69.5, msg="expected mid-flight height in (0.5, 69.5) at +step, got \{h1}")
  t.run_for(step)
  let h2 = room.placed_now().3
  assert_true(h2 >= h1 && h2 <= 70.01, msg="expected monotonic progress at +2*step: \{h1} -> \{h2}")
  t.run_for(move_most_ms)
  let h_end = room.placed_now().3
  assert_true((h_end - 70.0).abs() < 0.01, msg="expected final room height 70.0, got \{h_end}")
}
