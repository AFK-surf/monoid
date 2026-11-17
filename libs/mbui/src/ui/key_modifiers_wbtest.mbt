// A control follows modifier-only input, and a field's submit sees the modifiers of the key that submitted it.

///|
test "modifier changes reach bindings and a submitted field at the input's moment" {
  let f = Field::new()
  let submitted : Array[Int] = []
  let t = Tester::new(fn(_) {  }, w=300.0, h=200.0)
  set_view_app(fn(root) {
    root.box(fn(col) {
      col.box(fn(label) {
        label.words(By(fn() { if (key_modifiers() & mod_cmd) != 0 { "Dispatch" } else { "Add" } })) |> ignore
      }) |> ignore
      field(col, f, enter_sends=true, submitted=fn(_) { submitted.push(key_modifiers()) }) |> ignore
    }) |> ignore
  })
  t.draw()
  f.focus()
  t.draw()
  assert_true(t.words().iter().any(fn(w) { w.0 == "Add" }))
  t.hold_mods(mod_cmd)
  t.draw()
  assert_true(t.words().iter().any(fn(w) { w.0 == "Dispatch" }))
  t.key(key_enter, mods=mod_cmd)
  assert_eq(submitted, [mod_cmd])
  t.hold_mods(0)
  t.draw()
  assert_true(t.words().iter().any(fn(w) { w.0 == "Add" }))
}
