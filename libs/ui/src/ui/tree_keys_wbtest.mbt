///|
/// A window: a key catcher of the tree's 200 × 200 at its top left (on while `on` holds), a modal layer over all of it
/// while `modal` holds; what it was told.
fn tree_keys_window(on : @signals.Signal[Bool], modal : @signals.Signal[Bool]) -> (Tester, Array[KeyIn], Ref[@view.View?]) {
  let told : Array[KeyIn] = []
  let caught : Ref[@view.View?] = Ref(None)
  let t = Tester::new(fn(_c) {  }, platform=0, keyboard=true)
  set_view_app(fn(root) {
    root
    .show(fn() { on.get() }, fn(s) {
      key_catcher_node(s, "keys", fn(k) { told.push(k) }, fn(k) {
        caught.val = Some(k)
        k.width(Is(Some(200.0))).height(Is(Some(200.0))) |> ignore
      })
      |> ignore
    })
    |> ignore
    root.box(fn(l) { l.over(Is(true)).modal(By(fn() { modal.get() })) |> ignore }) |> ignore
  })
  t.draw()
  (t, told, caught)
}

///|
test "a key catcher of the tree's: pressed, it takes the keyboard and is told each word and key as it comes" {
  let (t, told, _) = tree_keys_window(@signals.signal(true), @signals.signal(false))
  assert_false(t.key_catching())
  t.tap(100.0, 100.0)
  assert_true(t.key_catching(), msg="pressed, the host told to take the keyboard for it")
  t.type_text("ls")
  t.key(key_code_enter)
  t.key(1000 + 'c'.to_int(), mods=mod_ctrl)
  assert_eq(told, [
    Text("ls"),
    Key(down=true, key="Enter", code="Enter", mods=0),
    Key(down=false, key="Enter", code="Enter", mods=0),
    Key(down=true, key="c", code="KeyC", mods=key_in_ctrl),
    Key(down=false, key="c", code="KeyC", mods=key_in_ctrl),
  ])
}

///|
test "a key catcher of the tree's: under a modal layer it is told nothing; let go, the keyboard is the host's again" {
  let on = @signals.signal(true)
  let modal = @signals.signal(false)
  let (t, told, caught) = tree_keys_window(on, modal)
  key_catcher_focus_set(caught.val.unwrap(), true)
  t.draw()
  assert_true(t.key_catching())
  assert_eq(t.edit_can(), @hostapi.text_menu_paste)
  modal.set(true)
  t.draw()
  assert_eq(t.edit_can(), 0)
  t.type_text("x")
  assert_eq(told, [], msg="kept from input by the layer over it")
  modal.set(false)
  on.set(false)
  t.draw()
  t.type_text("y")
  assert_eq(told, [], msg="let go")
  assert_false(t.key_catching(), msg="no catcher has the focus")
  assert_eq(t.edit_can(), 0)
}

///|
test "key_reaches_node follows focus, key catchers, on_key nodes, modals, and app foreground state reactively" {
  let modal = @signals.signal(false)
  let target_ref : Ref[@view.View?] = Ref(None)
  let btn_ref : Ref[@view.View?] = Ref(None)
  let on_key_ref : Ref[@view.View?] = Ref(None)
  let catcher_ref : Ref[@view.View?] = Ref(None)
  let field_state = Field::new()
  let reached_log : Array[Bool] = []
  let t = Tester::new(fn(_c) {  }, platform=0, keyboard=true)
  set_view_app(fn(root) {
    root.box(fn(box) {
      target_ref.val = Some(box)
      box.width(Is(Some(400.0))).height(Is(Some(400.0))) |> ignore
      box.box(fn(b) {
        btn_ref.val = Some(b)
        b.width(Is(Some(80.0))).height(Is(Some(40.0))).focusable(Is(true)).on_press(fn() {  }) |> ignore
      })
      |> ignore
      box.box(fn(k) {
        on_key_ref.val = Some(k)
        k
        .width(Is(Some(80.0)))
        .height(Is(Some(40.0)))
        .focusable(Is(true), keys=0)
        .on_key(fn(ev) { ev.code == key_space })
        |> ignore
      })
      |> ignore
      key_catcher_node(box, "term", fn(_) {  }, fn(k) {
        catcher_ref.val = Some(k)
        k.width(Is(Some(80.0))).height(Is(Some(40.0))) |> ignore
      })
      |> ignore
      field(box, field_state, placeholder="msg") |> ignore
      box.reacts(fn() { key_reaches_node(box, key_space, 0) }, fn(v) { reached_log.push(v) })
    })
    |> ignore
    root.box(fn(l) { l.over(Is(true)).modal(By(fn() { modal.get() })) |> ignore }) |> ignore
  })
  t.draw()
  let target = target_ref.val.unwrap()
  assert_true(key_reaches_node(target, key_space, 0), msg="unfocused foreground")
  // Button with focus_space blocks Space, but not Cmd+K.
  assert_true(btn_ref.val.unwrap().ask_focus(visible=true))
  t.draw()
  assert_false(key_reaches_node(target, key_space, 0), msg="space-taking button focused")
  assert_true(key_reaches_node(target, key_of_char('k'), mod_cmd), msg="modified shortcut still reaches with button focused")
  t.ctx().blur()
  t.draw()
  assert_true(key_reaches_node(target, key_space, 0), msg="after button blur")
  // Node with keys=0 + on_key blocks Space.
  assert_true(on_key_ref.val.unwrap().ask_focus(visible=true))
  t.draw()
  assert_false(key_reaches_node(target, key_space, 0), msg="on_key focusable node blocks Space")
  t.ctx().blur()
  t.draw()
  assert_true(key_reaches_node(target, key_space, 0), msg="after on_key blur")
  // Key catcher blocks all shortcuts.
  key_catcher_focus_set(catcher_ref.val.unwrap(), true)
  t.draw()
  assert_false(key_reaches_node(target, key_space, 0), msg="key catcher blocks Space")
  assert_false(key_reaches_node(target, key_of_char('k'), mod_cmd), msg="key catcher blocks Cmd+K")
  t.ctx().blur()
  t.draw()
  assert_true(key_reaches_node(target, key_space, 0), msg="after catcher blur")
  // Text field blocks unless in_field=true.
  field_state.focus()
  t.draw()
  assert_false(key_reaches_node(target, key_space, 0), msg="text field blocks Space")
  assert_true(key_reaches_node(target, key_of_char('k'), mod_cmd, in_field=true), msg="in_field allows Cmd+K")
  // Clear focus -> reaches again.
  t.ctx().blur()
  t.draw()
  assert_true(key_reaches_node(target, key_space, 0), msg="after field blur")
  // Modal layer blocks target.
  modal.set(true)
  t.draw()
  assert_false(key_reaches_node(target, key_space, 0), msg="modal over target blocks Space")
  modal.set(false)
  t.draw()
  assert_true(key_reaches_node(target, key_space, 0), msg="modal closed restores Space")
  // App unfocused blocks Space.
  t.app_state(true, false)
  t.draw()
  assert_false(key_reaches_node(target, key_space, 0), msg="background window blocks Space")
  t.app_state(true, true)
  t.draw()
  assert_true(key_reaches_node(target, key_space, 0), msg="foreground window restores Space")
  assert_eq(
    reached_log,
    [true, false, true, false, true, false, true, false, true, false, true, false, true],
    msg="each blocker and recovery must reactively flip key_reaches_node",
  )
}
