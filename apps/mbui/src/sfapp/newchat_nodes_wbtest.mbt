// A new chat made as nodes (sfpages new_chat_node.mbt), where the chat's page and its composer are (sfbase's
// chat_page_nodes: 试用新对话页 on): the same
// page on a phone (窄排法: its scene over the band of its choices and composer at the foot) and in a desk's window
// (宽排法: the scene over the roomy composer, its choices in its row), what it is for, where it runs and on what picked
// through the presenters, and the old view none of it.

///|
/// A Tester of the app over the fixture's `mode` with the chat's page and its composer made as nodes, its new chat
/// opened (open_mode) and
/// at rest: a phone's window, or a desk's (`wide`: 1280 by 800, a mouse).
fn nodes_new_chat(mode : String, wide? : Bool = false) -> @ui.Tester {
  new_run()
  @sfbase.hold_chat_page_nodes(Some(true))
  let src = fixture(mode)
  let t = if wide {
    @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  } else {
    @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  }
  open_mode(mode)
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// Where `words` are drawn now, seen (a node's): the first.
fn node_words_at(t : @ui.Tester, words : String) -> (Double, Double)? {
  for w in t.words() {
    if w.0 == words && w.5 > 0.5 {
      return Some((w.1, w.2))
    }
  }
  None
}

///|
test "a new chat made as nodes on a phone: its scene, where it runs and on what over the composer at the foot" {
  let t = nodes_new_chat("newchat")
  assert_true(app.nav.top() is NewChat)
  for words in ["取消", "新对话", "想让 agent 做什么？", "描述要做的事。它会在 Willow 上使用所选模型新建会话。", "Willow", "Opus 5.5", "做任何事"] {
    assert_true(node_words_at(t, words) is Some(_), msg="\{words}: \{runs(t)}")
  }
  // the choices over the composer, both at the window's foot, the scene over them
  let (_, title_y) = node_words_at(t, "想让 agent 做什么？").unwrap()
  let (_, model_y) = node_words_at(t, "Opus 5.5").unwrap()
  let (_, field_y) = node_words_at(t, "做任何事").unwrap()
  assert_true(title_y < model_y && model_y < field_y && field_y > 700.0, msg="\{title_y} \{model_y} \{field_y}")
  assert_true(t.query(Button, label="预设") is Some(_), msg=t.semantics_dump())
}

///|
test "a new chat made as nodes: its station picked in the sheet, its model in the model's panel, cancelled" {
  let t = nodes_new_chat("newchat")
  let (sx, sy) = node_words_at(t, "Willow").unwrap()
  t.tap(sx + 4.0, sy + 4.0)
  assert_true(shows(t, "选择运行的 station"), msg=runs(t))
  presented_rested(t)
  let (mx, my) = t.find_last("Maple").unwrap()
  t.tap(mx, my)
  t.run_for(@ui.move_most_ms)
  assert_true(!@sf.presented_open_of(@sf.last_presented()))
  assert_eq(new_fix.station, "st2")
  assert_true(node_words_at(t, "描述要做的事。它会在 Maple 上使用所选模型新建会话。") is Some(_), msg=runs(t))
  let (ox, oy) = node_words_at(t, "Opus 5.5").unwrap()
  t.tap(ox + 4.0, oy + 4.0)
  t.run_for(@ui.move_most_ms)
  assert_true(shows(t, "思考深度"), msg=runs(t))
  run_to_sheet_rest(t)
  let (gx, gy) = t.find_last("GPT-6").unwrap()
  t.tap(gx, gy)
  t.run_for(@ui.move_most_ms)
  assert_true(!@sf.presented_open_of(@sf.last_presented()))
  assert_true(node_words_at(t, "GPT-6") is Some(_), msg=runs(t))
  // cancelled, it sinks back down
  let (cx, cy) = node_words_at(t, "取消").unwrap()
  t.tap(cx + 4.0, cy + 4.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(app.nav.depth(), 1)
}

///|
test "a new chat made as nodes: its preset's control opens the presets to pick" {
  let t = nodes_new_chat("newchat")
  press(t, "预设")
  t.run_for(@ui.move_most_ms)
  assert_false(shows(t, "不用预设"), msg=runs(t))
  assert_true(shows(t, "still.fail 开发") && shows(t, "新预设"), msg=runs(t))
}

///|
test "a new chat made as nodes in a desk's window: the scene over the roomy composer, its choices in its row, the composer in the middle" {
  let t = nodes_new_chat("newchat", wide=true)
  // (with keyboard and mouse and nothing focused, the composer says the key that brings the cursor to it)
  for words in ["想让 agent 做什么？", "描述要做的事。它会在 Willow 上使用所选模型新建会话。", "预设", "Willow", "Opus 5.5", "按空格输入"] {
    assert_true(node_words_at(t, words) is Some(_), msg="\{words}: \{runs(t)}")
  }
  let (_, title_y) = node_words_at(t, "想让 agent 做什么？").unwrap()
  let (_, field_y) = node_words_at(t, "按空格输入").unwrap()
  let (_, model_y) = node_words_at(t, "Opus 5.5").unwrap()
  // (its words over its row of choices, in the window's middle)
  assert_true(title_y < field_y && field_y < model_y, msg="\{title_y} \{field_y} \{model_y}")
  assert_true(field_y > 250.0 && model_y < 600.0, msg="\{field_y} \{model_y}")
}

///|
test "a new chat made as nodes sends its first message: the page is the chat in place, its scene gone once it has left" {
  let t = nodes_new_chat("newchat")
  let (fx, fy) = node_words_at(t, "做任何事").unwrap()
  t.tap(fx + 4.0, fy + 4.0)
  t.type_text("把发布说明写一下")
  t.draw()
  tap_send(t)
  t.draw()
  match app.nav.top() {
    Chat(r) => assert_eq(r.session, "new:1")
    _ => fail("not the chat")
  }
  t.run_for(@sfbase.new_leave_ms + @ui.move_most_ms)
  assert_true(node_words_at(t, "想让 agent 做什么？") is None, msg=runs(t))
  assert_true(shows(t, "把发布说明写一下"), msg=runs(t))
}

///|
test "a new chat made as nodes laid out narrow and wide again as its window changes: one field all along, the cursor and what is typed in it kept" {
  let t = nodes_new_chat("newchat", wide=true)
  let narrow_seen = Ref(false)
  t.tap_text("按空格输入")
  t.type_text("把发布说明写一下")
  t.run_for(@ui.move_most_ms)
  let field = fn() {
    match t.query(TextField) {
      Some(f) => (Some(f.id), f.value)
      None => (None, "")
    }
  }
  let (id, words) = field()
  assert_true(id is Some(_), msg=t.semantics_dump())
  assert_eq(words, "把发布说明写一下")
  // (the window 900 wide, still 大屏: the pane beside the sidebar under page_narrow_most, the page laid out narrow, its
  // choices in glass over the same field at its foot; then wide again)
  for size in [(900.0, 800.0), (1280.0, 800.0)] {
    t.resize(size.0, size.1)
    t.run_for(@ui.move_most_ms)
    let (now, said) = field()
    let (focused, typed, _, _) = t.ime()
    assert_eq((now, said, focused, typed), (id, words, true, words), msg="at \{size.0}")
    // (narrow: the band of glass across the pane's foot, its choices over the composer)
    if size.0 < 1000.0 {
      narrow_seen.val = t.drawn_glass().iter().any(fn(g) { g.2 > 500.0 && g.2 < 700.0 && g.1 > 500.0 })
    }
  }
  assert_true(narrow_seen.val, msg="the page not laid out narrow at 900")
  assert_true(node_words_at(t, "Opus 5.5") is Some(_), msg=runs(t))
}
