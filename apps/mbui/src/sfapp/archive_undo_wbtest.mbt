// 归档's 归档后可撤销 (the prefs' `archiveUndo`, sfbase's archive_undo_on): on, a chat archived from its row leaves its
// tray with 撤销 in its place for a moment; off, the row goes at once and nothing offers 撤销, a toast saying it.

///|
test "归档后可撤销 in 归档 turned off: the prefs' archiveUndo off; on again, none kept" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, w=390.0, h=844.0, platform=2)
  app.nav.push(Settings)
  app.nav.push(Setting(@settings.Route::Archiving))
  t.draw()
  t.run_for(@ui.move_most_ms)
  t.click(Switch, label="归档后可撤销")
  t.frame()
  t.frame()
  let set = named(calls, "prefs.set")
  assert_eq(text(Some(set[set.length() - 1].params), "archiveUndo"), "off")
  t.click(Switch, label="归档后可撤销")
  t.frame()
  t.frame()
  let set = named(calls, "prefs.set")
  assert_true(field(Some(set[set.length() - 1].params), "archiveUndo") is Some(Null))
}

///|
test "归档后可撤销 off: a chat archived from its row's menu goes at once, no tray and no 撤销, a toast with nothing to undo" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, w=390.0, h=844.0, platform=2, before=fn(src) {
    (src.call)("prefs.set", { "archiveUndo": "off" }, fn(_) {  })
  })
  let title = "夜里的构建又失败了"
  let (_, y0, _, _) = t.rect_of(title).unwrap()
  hold_row(t, title)
  let (lx, ly) = t.find_last("归档").unwrap()
  t.tap(lx, ly)
  assert_eq(named(calls, "chat.archive").length(), 1)
  t.draw()
  // (said by the toast, no 撤销 on it; nothing said in the row's place)
  assert_eq(app.toast.get().words, "已归档「\{title}」")
  assert_eq(app.toast.get().action, "")
  assert_true(t.query(Status, label="已归档") is None)
  t.run_for(@ui.move_most_ms)
  assert_true(!row_undo(t, y0))
  assert_true(t.locate("=撤销").is_empty())
  // (its row gone from the list: its title only in the toast's words)
  t.run_for(@ui.row_size_ms)
  assert_true(t.locate("=\{title}").is_empty(), msg="\{Repr(t.locate("=\{title}"))}")
}

///|
test "归档后可撤销 off: a row swiped off goes at once, no tray and no 撤销" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, w=390.0, h=844.0, platform=2, before=fn(src) {
    (src.call)("prefs.set", { "archiveUndo": "off" }, fn(_) {  })
  })
  let title = "夜里的构建又失败了"
  let (_, y0, _, _) = t.rect_of(title).unwrap()
  t.drag(340.0, y0 + 4.0, 120.0, y0 + 4.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(named(calls, "chat.archive").length(), 1)
  assert_eq(app.toast.get().action, "")
  assert_true(t.locate("=撤销").is_empty())
  // (its line closing at once, as a row gone from the list does: nothing of it left, no tray held in its place)
  t.run_for(@ui.row_size_ms)
  assert_true(t.locate("=\{title}").is_empty(), msg="\{Repr(t.locate("=\{title}"))}")
  assert_true(t.query(Status, label="已归档") is None)
  assert_true(t.locate("=撤销").is_empty())
}

///|
test "归档后可撤销 on (none kept): a chat archived from its row's menu leaves its tray with 撤销 in its place, no toast" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, w=390.0, h=844.0, platform=2)
  let title = "夜里的构建又失败了"
  let (_, y0, _, _) = t.rect_of(title).unwrap()
  hold_row(t, title)
  let (lx, ly) = t.find_last("归档").unwrap()
  t.tap(lx, ly)
  assert_eq(named(calls, "chat.archive").length(), 1)
  t.draw()
  assert_true(t.query(Status, label="已归档") is Some(_))
  t.run_for(@ui.move_most_ms)
  assert_true(row_undo(t, y0))
  assert_eq(app.toast.get().words, "")
}
