// The new chat's presets' menu (sfpages presets.mbt) as a person's own and the other members' (the user, 2026-11-14:
// 「用户默认只能看到自己的预设，想要查看别人的预设需要额外操作」): the menu lists one's own; 其他成员的预设 under its
// line a level further in, asked of the core at that press and opened whole; someone else's picked there the page's,
// shown checked with whose it is, 复制「X」为我的预设 in place of 编辑 (the lead, 2026-11-14: never edited or deleted here).

///|
/// The fixture's source for `mode`, the calls made kept in `calls` and the topics asked in `asked` (by name, as each is
/// first read).
fn others_src(mode : String, calls : Array[Made], asked : Array[String]) -> Source {
  let base = preset_calls(mode, calls)
  {
    ..base,
    topic_read: fn(name, params) {
      asked.push(name)
      (base.topic_read)(name, params)
    },
  }
}

///|
/// The menu's row of `words` chosen, as a hand presses it (a failure saying what is there where it is not shown).
fn choose(t : @ui.Tester, words : String) -> Unit raise {
  guard shows(t, words) else { fail("no \{words}: \{runs(t)}") }
  t.tap_text(words)
}

///|
test "the presets' menu lists one's own, 其他成员的预设 under its line, nobody else's" {
  for wide in [false, true] {
    new_run()
    let asked : Array[String] = []
    let t = preset_mode("newchat-preset", wide~, src=others_src("newchat-preset", [], asked))
    assert_false(shows(t, "不用预设"), msg=runs(t))
    assert_true(shows(t, "still.fail 开发") && shows(t, "web-app + backend"), msg=runs(t))
    assert_true(shows(t, "新预设") && shows(t, "其他成员的预设"), msg=runs(t))
    assert_false(shows_start(t, "线上排障") || shows_start(t, "文档站"), msg=runs(t))
    // (the others' asked of no station till it is pressed)
    assert_false(asked.contains("otherPresets"), msg="wide \{wide}: \{Repr(asked)}")
  }
}

///|
test "其他成员的预设 asks for them at the press and opens once every station has answered, each with whose it is" {
  for wide in [false, true] {
    new_run()
    @sffixture.new_fix.others_reading = true
    let asked : Array[String] = []
    let t = preset_mode("newchat-preset", wide~, src=others_src("newchat-preset", [], asked))
    choose(t, "其他成员的预设")
    t.run_for(@ui.move_most_ms)
    assert_true(asked.contains("otherPresets"), msg="\{Repr(asked)}")
    // (still asked: not opened on what has come so far, the menu it was chosen in held as it was meanwhile)
    assert_false(shows_start(t, "线上排障") || shows(t, "其他成员还没有预设"), msg=runs(t))
    assert_true(shows(t, "web-app + backend") && shows(t, "其他成员的预设"), msg="wide \{wide}: the menu let go of as it waits: \{runs(t)}")
    @sffixture.fix_others_say()
    t.run_for(@ui.move_most_ms)
    assert_true(shows(t, "线上排障") && shows_start(t, "林夏") && shows(t, "文档站") && shows_start(t, "Mia Chen"), msg="wide \{wide}: \{runs(t)}")
    // (one's own not among them)
    assert_false(shows(t, "web-app + backend"), msg=runs(t))
    // (on a sheet a level of the panel it was chosen in, as one answered already is: back is that one again)
    if !wide {
      t.back()
      t.run_for(@ui.move_most_ms)
      assert_true(shows(t, "web-app + backend") && shows(t, "其他成员的预设"), msg=runs(t))
    }
  }
}

///|
test "answered already, 其他成员的预设 is a level of the same menu, back going back to one's own" {
  new_run()
  let t = preset_mode("newchat-preset")
  choose(t, "其他成员的预设")
  t.run_for(@ui.move_most_ms)
  assert_true(shows(t, "线上排障") && shows_start(t, "林夏"), msg=runs(t))
  t.back()
  t.run_for(@ui.move_most_ms)
  assert_true(shows(t, "web-app + backend") && shows(t, "其他成员的预设"), msg=runs(t))
}

///|
test "someone else's preset picked there is the new chat's, the menu closed" {
  new_run()
  let calls : Array[Made] = []
  let t = preset_mode("newchat-preset", src=others_src("newchat-preset", calls, []))
  choose(t, "其他成员的预设")
  t.run_for(@ui.move_most_ms)
  choose(t, "线上排障")
  t.run_for(@ui.move_most_ms)
  let picked = Some(named(calls, "newChat.pick").last().unwrap().params)
  assert_eq(text(picked, "preset"), "p-ops")
  assert_eq(text(picked, "presetStation"), "ws1/st1")
  assert_false(shows(t, "文档站"), msg=runs(t))
  // (the control says it)
  assert_true(t.query(Button, label="线上排障") is Some(_), msg=t.semantics_dump())
}

///|
test "with none from other members, the level says so in one line" {
  new_run()
  let t = preset_mode("newchat-preset-others-none")
  assert_true(shows(t, "其他成员还没有预设"), msg=runs(t))
}

///|
test "with someone else's picked, the panel shows it checked with whose it is and a copy action, never edit" {
  for wide in [false, true] {
    new_run()
    // (picked before the window is made: a wide frame asks its new chat as it is made, ahead of the mode)
    @sffixture.new_fix.preset = "p-ops"
    let t = preset_mode("newchat-preset-theirs", wide~)
    assert_true(shows(t, "线上排障") && shows_start(t, "林夏") && shows(t, "still.fail 开发"), msg="wide \{wide}: \{runs(t)}")
    assert_true(t.query(Button, label="复制 线上排障 为我的预设") is Some(_), msg=t.semantics_dump())
    assert_false(t.query(Button, label="线上排障 的更多操作") is Some(_), msg=t.semantics_dump())
  }
}

///|
test "copy action on someone else's preset copies it into one's own, picks the copy and opens its dialog to change it" {
  new_run()
  let calls : Array[Made] = []
  let t = preset_mode("newchat-preset-theirs", src=others_src("newchat-preset-theirs", calls, []))
  press(t, "复制 线上排障 为我的预设")
  t.run_for(@ui.move_most_ms)
  let copied = named(calls, "preset.copy")
  guard copied.length() == 1 else { fail("no preset.copy: \{Repr(calls.map(fn(m) { m.name }))}") }
  assert_eq(text(Some(copied[0].params), "id"), "p-ops")
  assert_eq(text(Some(copied[0].params), "station"), "ws1/st1")
  let picked = Some(named(calls, "newChat.pick").last().unwrap().params)
  assert_eq(text(picked, "preset"), "p-2")
  assert_eq(text(picked, "presetStation"), "ws1/st1")
  // (its dialog, its folder and 删除: one's own now)
  assert_true(shows(t, "编辑预设") && shows(t, "backend") && t.query(Button, label="删除") is Some(_), msg=runs(t))
}

///|
test "a control the other's preset holds offers 复制「X」为我的预设 and 不用预设, never 编辑" {
  new_run()
  @sffixture.new_fix.preset = "p-ops"
  @sffixture.new_fix.bound = true
  let t = preset_mode("newchat")
  // (the control by its role: the page's subtitle names the station too)
  guard t.query(Button, has="Willow") is Some(_) else { fail("no Willow: \{runs(t)}\n\{t.semantics_dump()}") }
  t.click(Button, has="Willow")
  t.run_for(@ui.move_most_ms)
  assert_true(shows_start(t, "Station 已被 ") && shows(t, "复制「线上排障」为我的预设") && shows(t, "不用预设"), msg=runs(t))
  assert_false(shows_start(t, "编辑「"), msg=runs(t))
}

///|
test "the presets' panels keep every rule, on a phone and on a desk" {
  let faults : Array[String] = []
  for mode in ["newchat-preset", "newchat-preset-many", "newchat-preset-others", "newchat-preset-others-none", "newchat-preset-theirs", "newchat-preset-theirs-long"] {
    for wide in [false, true] {
      new_run()
      let t = preset_mode(mode, wide~)
      // (the new chat's page under them, an old view's: theirs, not these panels')
      for f in t.audit() {
        if !f.contains("in an old view made at") {
          faults.push("\{mode} wide=\{wide}: \{f}")
        }
      }
    }
  }
  assert_eq(faults, [])
}

///|
test "editing another preset directly opens its dialog without changing the active preset" {
  new_run()
  let calls : Array[Made] = []
  let t = preset_mode("newchat-preset-many", wide=true, src=others_src("newchat-preset-many", calls, []))
  preset_more_edit(t, "微操")
  t.run_for(@ui.move_most_ms)
  assert_true(shows(t, "编辑预设"), msg=runs(t))
  assert_eq(named(calls, "newChat.pick").length(), 0)
}

///|
test "many presets show search field, filter by keyword, clear to restore, and Escape clears before closing" {
  new_run()
  let t = preset_mode("newchat-preset-many", wide=true)
  assert_true(shows(t, "搜预设") && shows(t, "架构师") && shows(t, "微操"), msg=runs(t))
  t.tap_text("搜预设")
  t.type_text("微")
  t.run_for(@ui.move_most_ms)
  assert_true(shows(t, "微操"), msg=runs(t))
  assert_false(shows(t, "Neon") || shows(t, "Astra"), msg=runs(t))
  // First Escape clears search without closing the panel
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_true(shows(t, "Neon") && shows(t, "微操") && shows(t, "Astra"), msg=runs(t))
  // Second Escape closes the panel
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_false(shows(t, "搜预设"), msg=runs(t))
}

///|
test "narrow phone with 1.3x English text passes audit on newchat-preset-many" {
  let t = screen_in("newchat-preset-many", ("narrow", 320.0, 640.0, 2, ""), "en", font_scale=1.3)
  let faults : Array[String] = []
  for f in t.audit() {
    if !f.contains("in an old view made at") {
      faults.push(f)
    }
  }
  assert_eq(faults, [])
}

///|
test "one's own preset made on another station is edited as the core holds it, its folders where each is" {
  // (the page on Maple, the preset made there as its station says: what Maple lists has none of it, the device all)
  new_run()
  @sffixture.new_fix.station = "st2"
  @sffixture.new_fix.preset = "p-sf"
  let t = preset_mode("newchat", wide=true)
  choose(t, "still.fail 开发")
  t.run_for(@ui.move_most_ms)
  preset_more_edit(t, "still.fail 开发")
  t.run_for(@ui.move_most_ms)
  assert_true(shows(t, "编辑预设") && shows(t, "still.fail 设计稿"), msg=runs(t))
}

///|
test "active preset shows quiet 不用预设 action in wide and narrow panels and clears preset on press" {
  for mode in ["newchat-preset-many", "newchat-preset-theirs"] {
    for wide in [false, true] {
      new_run()
      if mode == "newchat-preset-theirs" {
        @sffixture.new_fix.preset = "p-ops"
      }
      let calls : Array[Made] = []
      let t = preset_mode(mode, wide~, src=others_src(mode, calls, []))
      assert_true(shows(t, "不用预设"), msg="\{mode} wide=\{wide}: \{runs(t)}")
      press(t, "不用预设")
      let picks = named(calls, "newChat.pick")
      assert_true(picks.length() > 0, msg="\{mode} wide=\{wide}: no newChat.pick")
      assert_eq(text(Some(picks.last().unwrap().params), "preset"), "", msg="\{mode} wide=\{wide}")
    }
  }
}

///|
test "pressing the already-active preset row toggles it off" {
  for (mode, active_name) in [("newchat-preset-many", "架构师"), ("newchat-preset-theirs", "线上排障")] {
    new_run()
    if mode == "newchat-preset-theirs" {
      @sffixture.new_fix.preset = "p-ops"
    }
    let calls : Array[Made] = []
    let t = preset_mode(mode, wide=true, src=others_src(mode, calls, []))
    t.click(Button, label=active_name)
    let picks = named(calls, "newChat.pick")
    assert_true(picks.length() > 0, msg="\{mode}: no newChat.pick")
    assert_eq(text(Some(picks.last().unwrap().params), "preset"), "", msg=mode)
  }
}
