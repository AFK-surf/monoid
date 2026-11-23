///|
test "fake host auto_launch and hotkey registration round-trip" {
  let t = Tester::new(fn(_) {  })
  t.draw()
  assert_false(@hostapi.auto_launch())
  assert_true(@hostapi.set_auto_launch(true))
  assert_true(@hostapi.auto_launch())
  assert_true(t.fake.auto_launch)
  assert_true(@hostapi.set_auto_launch(false))
  assert_false(@hostapi.auto_launch())

  assert_false(@hostapi.hotkey_set("", "CmdOrCtrl+K"))
  assert_false(@hostapi.hotkey_set("quick", ""))
  assert_true(@hostapi.hotkey_set("quick", "CmdOrCtrl+Shift+Space"))
  assert_eq(t.fake.hotkeys.get("quick"), Some("CmdOrCtrl+Shift+Space"))
  assert_true(@hostapi.hotkey_set("quick", "Alt+K"))
  assert_eq(t.fake.hotkeys.get("quick"), Some("Alt+K"))
  @hostapi.hotkey_clear("quick")
  assert_eq(t.fake.hotkeys.get("quick"), None)
}
