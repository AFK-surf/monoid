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
