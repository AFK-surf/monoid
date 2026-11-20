// What an old view keeps by ids of its own let go with it (made.mbt's island_presses, island_lists): a page opened
// again and again, each time with ids of its own (an old view's ids made anew with each build of what holds it), keeps
// no more of it than one, and the rows the frames built are kept only as a test asks for them (Tester::rows_built).

///|
test "an old view let go takes back what it said by its ids: opened again and again, no more kept than of one" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  let on = @signals.signal(true)
  let made = Ref(0)
  set_view_app(fn(root) {
    root.box(fn(b) {
      b.show(at_once=true, fn() { on.get() }, fn(v) {
        v.width(Is(Some(100.0))).height(Is(Some(40.0))) |> ignore
        made.val += 1
        let k = made.val
        old(v, fn(c) {
          let id = c.id("press/\{k}")
          c.box(id~, w=Px(80.0), h=Px(30.0), fn() {  }) |> ignore
          c.on_press(id, fn() {  })
          c.on_double_press(id, fn() {  })
          c.after_build_or_scroll("tell/\{k}", fn() {  })
        })
        |> ignore
      })
    })
    |> ignore
  })
  t.draw()
  let first = (made_presses.length(), made_double_presses.length(), tells_follow_lists.length())
  for _ in 0..<30 {
    on.set(false)
    t.draw()
    on.set(true)
    t.draw()
  }
  assert_true(made.val > 30, msg="opened \{made.val} times")
  assert_eq(
    (made_presses.length(), made_double_presses.length(), tells_follow_lists.length()),
    first,
    msg="what the old views said by their ids, kept after \{made.val} opened",
  )
  assert_true(island_presses.length() <= 1, msg="\{island_presses.length()} old views' presses kept")
  assert_true(island_lists.length() <= 1, msg="\{island_lists.length()} old views' ids kept")
  // (none asked for the rows the frames built: none kept)
  assert_eq(nodes_run.built_at.length(), 0)
}

///|
test "an editor's handlers over a kept Field let go with the old view it was built in; a live one's kept" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  let on = @signals.signal(true)
  let other = @signals.signal(false)
  let f = Field::new()
  let sent = Ref(0)
  set_view_app(fn(root) {
    root.box(fn(b) {
      b.show(at_once=true, fn() { on.get() }, fn(v) {
        v.width(Is(Some(200.0))).height(Is(Some(40.0))) |> ignore
        old(v, fn(c) {
          c.editor("words", field=f, on_submit=fn(_) { sent.val += 1 }, on_edit=fn(_) {  }, look=fn(s) { (s, []) })
          |> ignore
        })
        |> ignore
      })
      b.show(at_once=true, fn() { other.get() }, fn(v) {
        v.width(Is(Some(200.0))).height(Is(Some(40.0))) |> ignore
        old(v, fn(c) { c.editor("words again", field=f, on_submit=fn(_) {  }) |> ignore }) |> ignore
      })
    })
    |> ignore
  })
  t.draw()
  assert_true(f.st.on_submit is Some(_) && f.st.on_edit is Some(_) && f.st.look is Some(_))
  on.set(false)
  t.draw()
  assert_true(
    f.st.on_submit is None && f.st.on_edit is None && f.st.on_change is None && f.st.look is None,
    msg="what the editor gone was told, kept by the Field",
  )
  // (another editor over the same Field, built since: what it was told kept as the first goes again)
  on.set(true)
  t.draw()
  on.set(false)
  other.set(true)
  t.draw()
  assert_true(f.st.on_submit is Some(_), msg="a live editor's handler let go with another's")
}
