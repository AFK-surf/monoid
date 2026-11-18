// A chat asked for here that its station never made (its first message did not go) has a menu of one item, 归档, done
// on the device alone; one still being made has none, as the core refuses archiving it till it is made.

///|
test "a chat whose first message did not go offers its menu, and that menu only archives it" {
  @sfbase.reset()
  reset()
  @sf.set_words(@sfbase.fill)
  let made = sample_chat(0)
  let failed = { ..made, session: "new:chat-0001", thread: None, pending: true, unsent: true, offline: Some("Offline") }
  let making = { ..failed, unsent: false, offline: None }
  assert_true(row_menu_offered(made))
  assert_false(row_menu_offered({ ..made, offline: Some("Offline") }))
  // (its station never had it: whether that station is reached does not matter)
  assert_true(row_menu_offered(failed))
  assert_false(row_menu_offered(making))
  let items = chat_menu_items(@sfbase.sample_source, failed, share_from=fn() { @sf.at_point(0.0, 0.0) })
  let labels = items.filter_map(fn(i) { i.map(fn(m) { m.label }) })
  assert_eq(labels, [@sf.t("web-main.chat.archive")])
  // (a made chat's menu has more than that)
  let all = chat_menu_items(@sfbase.sample_source, made, share_from=fn() { @sf.at_point(0.0, 0.0) })
  assert_true(all.filter_map(fn(i) { i }).length() > 1)
}
