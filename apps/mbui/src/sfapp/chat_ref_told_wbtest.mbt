// The composer's menu of chats to reference (sfpages' chat_ref.mbt: `@` and words) dismissed by the hand: Escape, a
// press away from the composer, closed for that `@` at that input's moment; the frame after closing nothing more.

///|
/// The desk's composer focused, "看 @首页" typed, its menu of chats shown: the Tester, whether that menu is closed for
/// its `@` (sfbase's refs_at none), and its source.
fn ref_menu_tester(calls? : Array[Made] = []) -> (@ui.Tester, () -> Bool, Source) raise {
  let (t, src) = desk_composer_tester(calls)
  desk_focus(t)
  t.type_text("看 @首页")
  t.frame()
  assert_true(t.find("引用对话") is Some(_), msg=t.words().map(fn(x) { x.0 }).join("|"))
  (t, fn() { @sfbase.refs_at("ws1/st1:s-c1") is None }, src)
}

///|
test "desk composer: its menu of chats dismissed by Escape: closed for that @ as the key is taken; the frame after closes nothing more" {
  both_pages(fn() raise {
    let (t, closed, _) = ref_menu_tester()
    let seen = [closed()]
    t.key_told(@ui.key_escape, 0, t.time())
    seen.push(closed())
    t.draw()
    seen.push(closed())
    t.run_for(@motion.pop_out_ms)
    assert_eq(seen, [false, true, true])
    assert_true(t.find("引用对话") is None)
    assert_true(composer_focused(), msg="the field keeps the focus")
  })
}

///|
test "desk composer: its menu of chats dismissed by a press away from the composer: closed for that @ as it goes down; the frame after closes nothing more" {
  both_pages(fn() raise {
    let (t, closed, _) = ref_menu_tester()
    // (above the menu, away from the composer: a press in the composer is its own, not the menu's dismissal)
    let (x, y) = (450.0, 20.0)
    let seen = [closed()]
    t.touch_at(0, x, y, t.time())
    seen.push(closed())
    t.touch_at(2, x, y, t.time())
    t.draw()
    seen.push(closed())
    assert_eq(seen, [false, true, true])
  })
}

///|
/// A chat pressed in the menu (as the host hands it on), then Escape at once, a frame between or none: how often it was
/// asked to be referenced, the words once the core has made its mark (the fixture's answering it), how often a message was sent, whether the field
/// keeps the focus.
fn ref_picked_then_escape(frames : Bool) -> (Int, String, Int, Bool) raise {
  let calls : Array[Made] = []
  let (t, _, src) = ref_menu_tester(calls~)
  let (x, y) = t.find("首页的列表改成按天分组").unwrap()
  t.touch_at(0, x, y, t.time())
  t.touch_at(2, x, y, t.time())
  if frames {
    t.frame()
  }
  t.key_told(@ui.key_escape, 0, t.time())
  t.draw()
  // (the fixture's core answers it, its mark in)
  let made = named(calls, "chat.ref")
  t.draw()
  (made.length(), desk_words(src), named(calls, "chat.send").length(), composer_focused())
}

///|
test "desk composer: a chat pressed in its menu, then Escape at once: referenced once, its mark in, nothing sent, the field keeping the focus, a frame between or none" {
  both_pages(fn() raise {
    let picked = (1, "看 @[首页的列表改成按天分组] ", 0, true)
    assert_eq((ref_picked_then_escape(false), ref_picked_then_escape(true)), (picked, picked))
  })
}

///|
/// The chat chosen in the menu (↓ ↑ round to the first, frames drawn), then `key` (Enter or Tab) and Escape at once as
/// the host hands them on, a frame between or none: as ref_picked_then_escape says.
fn ref_keyed_then_escape(key : Int, frames : Bool) -> (Int, String, Int, Bool) raise {
  let calls : Array[Made] = []
  let (t, _, src) = ref_menu_tester(calls~)
  t.key(@ui.key_code_down)
  t.key(@ui.key_code_up)
  t.frame()
  t.key_told(key, 0, t.time())
  if frames {
    t.frame()
  }
  t.key_told(@ui.key_escape, 0, t.time())
  t.draw()
  let made = named(calls, "chat.ref")
  t.draw()
  (made.length(), desk_words(src), named(calls, "chat.send").length(), composer_focused())
}

///|
test "desk composer: its menu of chats, Enter and Escape at once: the one chosen referenced once, its mark in, nothing sent, the field keeping the focus, a frame between or none" {
  both_pages(fn() raise {
    let picked = (1, "看 @[首页的列表改成按天分组] ", 0, true)
    assert_eq((ref_keyed_then_escape(@ui.key_code_enter, false), ref_keyed_then_escape(@ui.key_code_enter, true)), (picked, picked))
  })
}

///|
test "desk composer: its menu of chats, Tab and Escape at once: Tab puts the one chosen in (the focus staying in the field), once, a frame between or none" {
  both_pages(fn() raise {
    let picked = (1, "看 @[首页的列表改成按天分组] ", 0, true)
    assert_eq((ref_keyed_then_escape(@ui.key_tab, false), ref_keyed_then_escape(@ui.key_tab, true)), (picked, picked))
  })
}

///|
/// The menu of chats shown, then `first` (as the host hands it on, no frame after it) and Enter at once, a frame drawn
/// once both are told: how often a chat was referenced, the words, how often a message was sent.
fn ref_then_enter(first : (@ui.Tester) -> Unit) -> (Int, String, Int) raise {
  let calls : Array[Made] = []
  let (t, _, src) = ref_menu_tester(calls~)
  first(t)
  t.key_told(@ui.key_code_enter, 0, t.time())
  t.draw()
  t.draw()
  (named(calls, "chat.ref").length(), desk_words(src), named(calls, "chat.send").length())
}

///|
test "desk composer: its menu closed by Escape, then Enter before a frame: no chat referenced from the menu it closed, Enter the field's (it sends)" {
  both_pages(fn() raise {
    let (refs, words, sent) = ref_then_enter(fn(t) { t.key_told(@ui.key_escape, 0, t.time()) })
    assert_eq((refs, sent), (0, 1), msg=words)
  })
}

///|
test "desk composer: its menu, Enter twice before a frame: the one chosen referenced once, the second Enter the field's" {
  both_pages(fn() raise {
    let (refs, words, _) = ref_then_enter(fn(t) { t.key_told(@ui.key_code_enter, 0, t.time()) })
    assert_eq(refs, 1, msg=words)
  })
}

///|
test "desk composer: its menu, a letter typed, Enter and Escape before a frame: the one shown chosen put in for the @ and the letter, as Enter comes, the Escape after it closing nothing of it" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let (t, _, src) = ref_menu_tester(calls~)
    t.text_told("的", t.time())
    t.key_told(@ui.key_code_enter, 0, t.time())
    t.key_told(@ui.key_escape, 0, t.time())
    t.draw()
    t.draw()
    assert_eq((named(calls, "chat.ref").length(), desk_words(src), named(calls, "chat.send").length()), (1, "看 @[首页的列表改成按天分组] ", 0))
  })
}

///|
/// A finger's composer (Enter a line's end): two lines written, an `@` on the second, its menu shown, then `keys` as
/// the host hands them on, a frame between each or none: where the caret is then, and how often a chat was referenced.
fn ref_phone_then(keys : Array[Int], frames : Bool) -> (Int, Int, String) raise {
  let calls : Array[Made] = []
  let t = fake_core(calls)
  t.tap_text("发消息")
  t.type_text("第一行")
  t.enter()
  t.type_text("看 @首页")
  t.frame()
  let (_, words, _, _) = t.ime()
  assert_true(t.find("引用对话") is Some(_), msg=words)
  for k in keys {
    t.key_told(k, 0, t.time())
    if frames {
      t.frame()
    }
  }
  t.draw()
  let (_, words, _, caret) = t.ime()
  (caret, named(calls, "chat.ref").length(), words)
}

///|
test "a finger's composer: its menu closed by Escape, then ↑: the field's, the caret up a line, a frame between or none" {
  both_pages(fn() raise {
    for frames in [false, true] {
      let (caret, refs, words) = ref_phone_then([@ui.key_escape, @ui.key_code_up], frames)
      assert_true(caret <= "第一行".length() && refs == 0, msg="(frames \{frames}) caret \{caret} in \{words}")
    }
  })
}

///|
test "a finger's composer: a chat picked from its menu by Enter, then ↑ before a frame: the field's, the caret up a line" {
  both_pages(fn() raise {
    let (caret, refs, words) = ref_phone_then([@ui.key_code_enter, @ui.key_code_up], false)
    assert_true(caret <= "第一行".length() && refs == 1, msg="caret \{caret} refs \{refs} in \{words}")
  })
}

///|
test "desk composer: its menu for an @ with words after it: Enter puts the one chosen in for the @ and what follows it to the caret, the words after the caret as they were" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let (t, src) = desk_composer_tester(calls)
    desk_focus(t)
    t.type_text("看 @首页 后文")
    for _ in 0..<3 {
      t.key(@ui.key_code_left)
    }
    t.frame()
    t.frame()
    assert_true(t.find("引用对话") is Some(_), msg=desk_words(src))
    t.key(@ui.key_code_enter)
    t.draw()
    t.draw()
    let words = desk_words(src)
    assert_eq((named(calls, "chat.ref").length(), words.has_prefix("看 @[首页的列表改成按天分组] "), words.has_suffix(" 后文")), (1, true, true), msg=words)
  })
}

///|
test "desk composer: its menu, `[` typed after its @ and the core's answer for it drawn (no chat): Enter is the field's, no chat referenced" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let (t, _, src) = ref_menu_tester(calls~)
    t.type_text("[")
    t.frame()
    t.frame()
    // (made as nodes, the menu going out on its way: pop_out_ms, offers_node's)
    t.run_for(@motion.pop_out_ms)
    assert_true(t.find("引用对话") is None, msg=desk_words(src))
    t.key_told(@ui.key_code_enter, 0, t.time())
    t.draw()
    assert_eq(named(calls, "chat.ref").length(), 0, msg=desk_words(src))
  })
}

///|
test "desk composer: its menu for an @ with words after it, the caret moved into those words and Enter before a frame: not the menu's, the words after the @ not taken as its" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let (t, src) = desk_composer_tester(calls)
    desk_focus(t)
    t.type_text("看 @首页 后文")
    for _ in 0..<3 {
      t.key(@ui.key_code_left)
    }
    t.frame()
    t.frame()
    assert_true(t.find("引用对话") is Some(_), msg=desk_words(src))
    // (into the words after it, as the host hands the keys on, no frame)
    t.key_told(@ui.key_code_right, 0, t.time())
    t.key_told(@ui.key_code_right, 0, t.time())
    t.key_told(@ui.key_code_enter, 0, t.time())
    t.draw()
    t.draw()
    assert_eq(named(calls, "chat.ref").length(), 0, msg=desk_words(src))
  })
}

///|
test "desk composer: its menu for an @ with words after it, the caret moved into those words, then the chat shown pressed before a frame: not the menu's, the words after the @ as they were" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let (t, src) = desk_composer_tester(calls)
    desk_focus(t)
    t.type_text("看 @首页 后文")
    for _ in 0..<3 {
      t.key(@ui.key_code_left)
    }
    t.frame()
    t.frame()
    assert_true(t.find("引用对话") is Some(_), msg=desk_words(src))
    let (cx, cy, cw, ch) = t.rect_of("首页的列表改成按天分组").unwrap()
    t.key_told(@ui.key_code_right, 0, t.time())
    t.key_told(@ui.key_code_right, 0, t.time())
    t.touch_at(0, cx + cw / 2.0, cy + ch / 2.0, t.time())
    t.touch_at(2, cx + cw / 2.0, cy + ch / 2.0, t.time())
    t.draw()
    t.draw()
    assert_eq((named(calls, "chat.ref").length(), desk_words(src)), (0, "看 @首页 后文"))
  })
}

///|
fn btw_app_tester(
  calls : Array[Made],
  w : Double,
  h : Double,
  platform : Int,
  chat_ref_answer? : Result[Json, Json]? = None,
) -> (@ui.Tester, Source) {
  new_run()
  let base = fixture("chat")
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      calls.push({ name, params, bytes: None, done })
      match (name, chat_ref_answer) {
        ("chat.ref", Some(ans)) => done(ans)
        _ => (base.call)(name, params, done)
      }
    },
  }
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~)
  t.run_for(@ui.move_most_ms)
  (t, src)
}

///|
test "parse_btw_command: recognizes /btw with optional question case-insensitively and ignores non-boundary prefixes" {
  assert_eq(@sfpages.parse_btw_command("/btw"), Some(""))
  assert_eq(@sfpages.parse_btw_command("  /btw  "), Some(""))
  assert_eq(@sfpages.parse_btw_command("/btw 帮我查一下这个报错"), Some("帮我查一下这个报错"))
  assert_eq(@sfpages.parse_btw_command("/BTW check this"), Some("check this"))
  assert_eq(@sfpages.parse_btw_command("/Btw\tmulti\nline "), Some("multi\nline"))
  assert_eq(@sfpages.parse_btw_command("/btwx"), None)
  assert_eq(@sfpages.parse_btw_command("/btwx hello"), None)
  assert_eq(@sfpages.parse_btw_command("/btw-1"), None)
  assert_eq(@sfpages.parse_btw_command("hello /btw"), None)
  assert_eq(@sfpages.parse_btw_command(""), None)
}

///|
test "/btw in chat composer jumps to NewChat with current chat @ref and optional question without calling chat.send" {
  for scene in [("大屏", 1280.0, 800.0, 0), ("小屏", 390.0, 844.0, 2)] {
    let (name, w, h, platform) = scene
    for case_ in [
      ("/btw", "@[整理发布清单] "),
      ("/btw 帮我查一下这个报错", "@[整理发布清单] 帮我查一下这个报错"),
      ("/BTW 大小写也生效", "@[整理发布清单] 大小写也生效"),
    ] {
      let (typed, expected) = case_
      let calls : Array[Made] = []
      let (t, src) = btw_app_tester(calls, w, h, platform)
      assert_true(app.nav.top() is Chat(_), msg="\{name}: starts on chat")
      desk_field_tap(t)
      t.type_text(typed)
      t.draw()
      tap_send(t)
      t.run_for(@ui.move_most_ms)
      assert_true(app.nav.top() is NewChat, msg="\{name} \{typed}: jumped to NewChat")
      assert_eq(named(calls, "chat.send").length(), 0, msg="\{name} \{typed}: chat.send not called")
      assert_eq(named(calls, "chat.ref").length(), 1, msg="\{name} \{typed}: chat.ref called once")
      assert_eq(@sfbase.writing(src, "ws1/st1:s-c1").field.text(), "", msg="\{name} \{typed}: chat draft cleared")
      assert_eq(
        @sfbase.writing(src, @sfpages.new_chat_drafts + "ws1").field.text(),
        expected,
        msg="\{name} \{typed}: new chat draft prefilled",
      )
    }
  }
}

///|
test "/btw preserves an existing NewChat draft on a following line" {
  let calls : Array[Made] = []
  let (t, src) = btw_app_tester(calls, 1280.0, 800.0, 0)
  let new_draft = @sfbase.writing(src, @sfpages.new_chat_drafts + "ws1")
  @sfbase.refs_put(new_draft.key, new_draft.field, "已有草稿")
  @sfbase.writing_text(src, new_draft, "已有草稿")
  desk_field_tap(t)
  t.type_text("/btw 顺便看下")
  t.draw()
  tap_send(t)
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() is NewChat)
  assert_eq(named(calls, "chat.send").length(), 0)
  assert_eq(
    @sfbase.writing(src, @sfpages.new_chat_drafts + "ws1").field.text(),
    "@[整理发布清单] 顺便看下\n已有草稿",
  )
}

///|
test "/btwx does not trigger /btw and sends normally through chat.send" {
  let calls : Array[Made] = []
  let (t, src) = btw_app_tester(calls, 1280.0, 800.0, 0)
  desk_field_tap(t)
  t.type_text("/btwx 普通消息")
  t.draw()
  tap_send(t)
  t.draw()
  t.draw()
  assert_true(app.nav.top() is Chat(_), msg="stays on chat")
  assert_eq(named(calls, "chat.ref").length(), 0, msg="chat.ref not called")
  assert_eq(named(calls, "chat.send").length(), 1, msg="chat.send called normally")
  assert_eq(@sfbase.writing(src, @sfpages.new_chat_drafts + "ws1").field.text(), "")
}

///|
test "/btw keeps question text and existing NewChat draft when chat.ref fails" {
  let calls : Array[Made] = []
  let (t, src) = btw_app_tester(calls, 1280.0, 800.0, 0, chat_ref_answer=Some(Err({ "message": "ref failed" })))
  let new_draft = @sfbase.writing(src, @sfpages.new_chat_drafts + "ws1")
  @sfbase.refs_put(new_draft.key, new_draft.field, "已有草稿")
  @sfbase.writing_text(src, new_draft, "已有草稿")
  desk_field_tap(t)
  t.type_text("/btw 顺便看下")
  t.draw()
  tap_send(t)
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() is NewChat)
  assert_eq(named(calls, "chat.send").length(), 0)
  assert_eq(@sfbase.writing(src, @sfpages.new_chat_drafts + "ws1").field.text(), "顺便看下\n已有草稿")
  assert_true(t.find("ref failed") is Some(_), msg="failure toast shown")
}

///|
test "/btw keeps question text and existing NewChat draft when chat.ref returns empty mark" {
  let calls : Array[Made] = []
  let (t, src) = btw_app_tester(calls, 1280.0, 800.0, 0, chat_ref_answer=Some(Ok({ "mark": "" })))
  let new_draft = @sfbase.writing(src, @sfpages.new_chat_drafts + "ws1")
  @sfbase.refs_put(new_draft.key, new_draft.field, "已有草稿")
  @sfbase.writing_text(src, new_draft, "已有草稿")
  desk_field_tap(t)
  t.type_text("/btw 帮我查一下这个报错")
  t.draw()
  tap_send(t)
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() is NewChat)
  assert_eq(named(calls, "chat.send").length(), 0)
  assert_eq(@sfbase.writing(src, @sfpages.new_chat_drafts + "ws1").field.text(), "帮我查一下这个报错\n已有草稿")
}
