// What takes a press where nothing of it is seen (tester_unseen_press.mbt): a row's key faded out under no hand is
// found, by the audit too, naming where it was made; shown under the hand, or said to take none while hidden, it is
// not; nor is a key in a pane faded out whole (a first page held unseen).

///|
/// How a row's key is hidden: always faded out; faded out but under the hand; that, taking presses only while shown;
/// that, taking a finger nowhere while hidden.
priv enum UnseenKey {
  Faded
  Hovered
  HoveredPressless
  HoveredNowhere
}

///|
/// How long after the hand moves a test looks: past any way the move sets off (none here: a look's switch is at once).
let unseen_hand_ms : Double = 100.0

///|
/// A row 300 by 48 at the window's top, its key 60 by 32 at its right end hidden as `key` says; the tester.
fn unseen_tester(key : UnseenKey) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=400.0, platform=0)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(row) {
      row
      .width(Is(Some(300.0)))
      .height(Is(Some(48.0)))
      .row(Is(true))
      .ground(Is(0xFFFFFFFFL))
      |> ignore
      row.box(fn(s) { s.grow(Is(1.0)) |> ignore }) |> ignore
      row.box(fn(k) {
        let shown = fn() { row.pointed() }
        k
        .width(Is(Some(60.0)))
        .height(Is(Some(32.0)))
        .ground(Is(0xCC3333FFL))
        .says(Is(Some(@view.said(Button, label="Remove"))))
        .on_press(fn() {  })
        |> ignore
        match key {
          Faded => k.alpha(Is(0.0)) |> ignore
          Hovered => k.alpha(By(fn() { if shown() { 1.0 } else { 0.0 } })) |> ignore
          HoveredPressless =>
            k.alpha(By(fn() { if shown() { 1.0 } else { 0.0 } })).presses(By(shown)) |> ignore
          HoveredNowhere =>
            k
            .alpha(By(fn() { if shown() { 1.0 } else { 0.0 } }))
            .takes(fn(w, h, _) { if shown() { [(0.0, 0.0, w, h)] } else { [] } })
            |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// The audit's lines that are `unseen press:`.
fn unseen_in_audit(t : Tester) -> Array[String] {
  t.audit().filter(fn(l) { l.has_prefix("unseen press:") })
}

///|
test "a row's key faded out, always or under no hand: its press found, by the audit too, naming where it was made" {
  for key in [Faded, Hovered] {
    let t = unseen_tester(key)
    // (the hand away from the row)
    t.move_to(350.0, 300.0)
    t.run_for(unseen_hand_ms)
    let found = t.unseen_press_faults()
    assert_eq(found.length(), 1, msg=found.join("\n"))
    assert_true(
      found[0].has_prefix("unseen press: a box (a node of the window's tree's at 240,0 60×32, made at ") &&
      found[0].contains("tester_unseen_press_wbtest.mbt:"),
      msg=found[0],
    )
    assert_eq(unseen_in_audit(t), found)
  }
}

///|
test "a row's key shown under the hand: no fault" {
  let t = unseen_tester(Hovered)
  t.move_to(350.0, 300.0)
  t.run_for(unseen_hand_ms)
  assert_eq(t.unseen_press_faults().length(), 1)
  // (over the row, beside its key)
  t.move_to(40.0, 24.0)
  t.run_for(unseen_hand_ms)
  assert_eq((t.unseen_press_faults(), unseen_in_audit(t)), ([], []))
}

///|
test "a row's key said to take no press, or a finger nowhere, while hidden: no fault, hidden or shown" {
  for key in [HoveredPressless, HoveredNowhere] {
    let t = unseen_tester(key)
    t.move_to(350.0, 300.0)
    t.run_for(unseen_hand_ms)
    let hidden = (t.unseen_press_faults(), unseen_in_audit(t))
    t.move_to(40.0, 24.0)
    t.run_for(unseen_hand_ms)
    assert_eq((hidden, t.unseen_press_faults()), (([], []), []))
  }
}

///|
test "a key in a pane faded out whole, as a first page is held unseen: the pane's wait, no fault" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=400.0, platform=0)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(pane) {
      pane.width(Is(Some(400.0))).height(Is(Some(400.0))).alpha(Is(0.0)) |> ignore
      pane.box(fn(k) {
        k
        .width(Is(Some(120.0)))
        .height(Is(Some(40.0)))
        .ground(Is(0x3366CCFFL))
        .says(Is(Some(@view.said(Button, label="Start"))))
        .on_press(fn() {  })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.run_for(unseen_hand_ms)
  assert_eq(t.unseen_press_faults(), [])
}
