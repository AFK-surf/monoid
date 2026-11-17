// A reminder in an agent's history: its label stays readable beside a long first line, and its whole text opens below.

///|
test "history reminder keeps its label on one line beside a long note and opens it whole" {
  let first = "This is a new conversation: your earlier one in this session is no longer available."
  let note = first + "\nThe agent can continue here."
  let item : Json = {
    "body": { "kind": "received", "content": { "note": Json::string(note), "tasks": [], "messages": [] } },
  }
  for lang in ["zh", "en"] {
    for case in [(240.0, 0), (360.0, 0), (360.0, 2), (580.0, 0)] {
      let (w, platform) = case
      steps_reset()
      @sf.set_words(@sfbase.fill)
      let src = @sffixture.fixture("history")
      // (the language as the device says it: what a test sets before its Tester is put back as the Tester starts)
      let t = @ui.Tester::new(
        fn(c) {
          @sf.begin(c) |> ignore
          c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
        },
        tree=fn(root) {
          @ui.set_tree_theme(@sf.ui_theme_now)
          let tips = @sf.TipLayer::new(fn() { Some(root) })
          root.box(fn(v) { item_node(v, src, "ws1/st1", "s-c1", "reminder", Some(item), false, tips) }) |> ignore
        },
        w~,
        h=240.0,
        platform~,
        env=[("MBUI_LOCALE", lang)],
      )
      t.draw()
      // (its words read once its run has begun)
      let title = @sf.t("web-main.history.reminder", args=[("name", "still.fail")])
      let at = "\{lang}, width \{w}, platform \{platform}"
      let (title_x, _, title_w, title_h) = t.rect_of(title).unwrap()
      let (line_x, _, _, line_h) = t.rect_of(first).unwrap()
      assert_true(title_h <= 20.0 && line_h <= 20.0, msg="\{at}: title \{title_h}, preview \{line_h}")
      assert_true(line_x >= title_x + title_w, msg=at)
      assert_true(t.rect_of(note) is None, msg=at)
      t.tap_text(title)
      // (its room opened on its way: reveal_node)
      t.run_for(@ui.move_most_ms)
      assert_true(t.rect_of(note) is Some(_), msg="\{at}: whole reminder did not open")
      let note_y = t.rect_of(note).unwrap().1
      assert_true(
        t.rect_of(title).unwrap().3 <= 20.0 && note_y > t.rect_of(title).unwrap().1,
        msg="\{at}: header row stays on one line while full reminder card opens below",
      )
      t.tap_text(title)
      t.run_for(@ui.move_most_ms)
      assert_true(t.rect_of(note) is None, msg="\{at}: reminder did not close")
      assert_true(t.rect_of(first).unwrap().1 <= 20.0, msg="\{at}: first-line preview stays on header row")
    }
  }
  steps_reset()
}

///|
/// A call's code (its part `kind: code`, as the core reads a call: history.tool) of `code` in a column 16 in from a
/// window 760 wide, drawn by the history's tool_part_node, or by an old view's code_block (`old`): its Tester, drawn.
fn steps_code_tester(old : Bool, code : String) -> @ui.Tester {
  let part : Json = { "kind": "code", "text": Json::string(code), "lang": "sh" }
  let t = if old {
    @ui.Tester::new(
      fn(c) {
        @sf.begin(c) |> ignore
        c.with_theme(@sf.ui_theme(), fn() { c.column(w=Fill(1.0), pad=16.0, fn() { @sf.code_block(c, code, "sh") }) |> ignore })
      },
      w=760.0,
      h=400.0,
    )
  } else {
    @ui.Tester::new(fn(c) { @sf.begin(c) |> ignore }, w=760.0, h=400.0, tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.lines_up(Is(None)) |> ignore
      root.box(fn(b) {
        b.padding(Is((16.0, 16.0, 16.0, 16.0))) |> ignore
        tool_part_node(b, Some(part))
      })
      |> ignore
    })
  }
  t.draw()
  t.draw()
  t
}

///|
/// Where each line of `code` is drawn in `t`, to a hundredth (Tester::run_rects: a rectangle a line).
fn steps_code_lines(t : @ui.Tester, code : String) -> Array[String] {
  code
  .split("\n")
  .to_array()
  .filter(fn(l) { l != "" })
  .map(fn(l) {
    let rects = t.run_rects(l.to_owned()).map(fn(r) { "\{(r.0 * 100.0).round() / 100.0},\{(r.1 * 100.0).round() / 100.0} \{(r.2 * 100.0).round() / 100.0}x\{(r.3 * 100.0).round() / 100.0}" })
    "\{l}: \{@ui.list_text(rects)}"
  })
}

///|
test "a call's code of two lines in the history: on two lines, each where an old view's code block draws it, as tall" {
  let code = "moon test --target wasm-gc src/sfpages/history_steps_node_wbtest.mbt\nmoon check"
  steps_reset()
  let old_t = steps_code_tester(true, code)
  let old = steps_code_lines(old_t, code)
  let old_box = old_t.rect_of("moon check")
  let made_t = steps_code_tester(false, code)
  let made = steps_code_lines(made_t, code)
  let made_box = made_t.rect_of("moon check")
  // (each line on a line of its own, the second under the first)
  let ys = fn(t : @ui.Tester) { ["moon test", "moon check"].map(fn(l) { t.run_rects(l).map(fn(r) { r.1 }) }) }
  assert_eq(made, old, msg="each line where an old view's code block draws it:\nmade \{Repr(made)}\nold  \{Repr(old)}")
  assert_eq(made_box, old_box, msg="its words as wide and as tall as an old view's: made \{Repr(made_box)}, old \{Repr(old_box)}")
  let lines = ys(made_t)
  assert_true(lines[0].length() == 1 && lines[1].length() == 1 && lines[1][0] > lines[0][0], msg="\{Repr(lines)}")
  steps_reset()
}

///|
test "history task stays one line collapsed and opens its result in a single card below" {
  let title = "后台任务「跑全量测试」已完成"
  let preview = "142 passed (18.4s)"
  let result = "moon test --target wasm-gc\n142 passed (18.4s)"
  let item : Json = {
    "body": {
      "kind": "received",
      "content": {
        "note": "",
        "tasks": [
          {
            "text": Json::string(title),
            "line": Json::string(preview),
            "result": Json::string(result),
            "md": [["p", [Json::string(result)]]],
            "failed": false,
            "agent": false,
          },
        ],
        "messages": [],
      },
    },
  }
  steps_reset()
  @sf.set_words(@sfbase.fill)
  let src = @sffixture.fixture("history")
  let t = @ui.Tester::new(fn(c) { @sf.begin(c) |> ignore }, w=480.0, h=240.0, tree=fn(root) {
    @ui.set_tree_theme(@sf.ui_theme_now)
    let tips = @sf.TipLayer::new(fn() { Some(root) })
    root.box(fn(v) { item_node(v, src, "ws1/st1", "s-c1", "h1", Some(item), false, tips) }) |> ignore
  })
  t.draw()
  assert_true(t.rect_of(title) is Some(_))
  assert_true(t.rect_of(preview) is None, msg="collapsed task does not dangle a second preview line")
  assert_true(t.rect_of(result) is None)
  let title_y = t.rect_of(title).unwrap().1
  t.tap_text(title)
  t.run_for(@ui.move_most_ms)
  assert_true(t.rect_of(title) is Some(_), msg="task title stays visible when expanded")
  assert_true(t.rect_of(result) is Some(_), msg="task result card opens below title")
  assert_true(t.rect_of(@sf.t("web-main.fold")) is None, msg="no 收起 words: the title's chevron turns")
  t.tap_text(title)
  t.run_for(@ui.move_most_ms)
  assert_true((t.rect_of(title).unwrap().1 - title_y).abs() < 0.5, msg="the title stays where it was pressed")
  assert_true(t.rect_of(title) is Some(_))
  assert_true(t.rect_of(result) is None)
  steps_reset()
}

///|
test "history text opens in a faint card below its header row and short single-line text omits fold button" {
  let short_words = "先看历史面板这几处样式。"
  let short_item : Json = {
    "body": {
      "kind": "text",
      "content": {
        "text": Json::string(short_words),
        "line": Json::string(short_words),
        "md": [["p", [Json::string(short_words)]]],
        "subagent": false,
      },
    },
  }
  let long_line = "列表只建看得见的行，其余的按估计的高度占位；量过一次的行记住它的高度。"
  let long_first_p = "列表只建看得见的行，其余的按估计的高度占位；"
  let long_detail = "展开后第二段内容收在浅底圆角框内，滚回来时不再跳。"
  let long_words = long_first_p + "\n" + long_detail
  let long_item : Json = {
    "body": {
      "kind": "text",
      "content": {
        "text": Json::string(long_words),
        "line": Json::string(long_line),
        "md": [["p", [Json::string(long_first_p)]], ["p", [Json::string(long_detail)]]],
        "subagent": false,
      },
    },
  }
  steps_reset()
  @sf.set_words(@sfbase.fill)
  let src = @sffixture.fixture("history")
  let t = @ui.Tester::new(fn(c) { @sf.begin(c) |> ignore }, w=420.0, h=300.0, tree=fn(root) {
    @ui.set_tree_theme(@sf.ui_theme_now)
    let tips = @sf.TipLayer::new(fn() { Some(root) })
    root.lines_up(Is(None)) |> ignore
    steps_box_node(root, steps_row_first, fn(v) { item_node(v, src, "ws1/st1", "s-c1", "short", Some(short_item), false, tips) })
    steps_box_node(root, steps_row_first, fn(v) { item_node(v, src, "ws1/st1", "s-c1", "long", Some(long_item), false, tips) })
  })
  t.draw()
  let (_, short_y, short_w, _) = t.rect_of(short_words).unwrap()
  let (_, long_y, long_w, long_h) = t.rect_of(long_line).unwrap()
  assert_true(short_w < 300.0 && long_w > short_w, msg="short single-line text fits on one line without truncation")
  assert_true(short_y < long_y && long_h <= 20.0)
  assert_true(t.rect_of(long_detail) is None)
  assert_true(t.rect_of(@sf.t("web-main.fold")) is None)
  let collapsed_y = long_y
  t.tap_text(long_line)
  t.run_for(@ui.move_most_ms)
  let (_, head_y, _, head_h) = t.rect_of(long_line).unwrap()
  let (_, expanded_y, _, _) = t.rect_of(long_detail).unwrap()
  assert_true(t.rect_of(@sf.t("web-main.fold")) is None, msg="no 收起 words: the chevron turns")
  assert_true(head_h <= 20.0 && (head_y - collapsed_y).abs() < 1.5, msg="header row stays on the first line: \{head_y} vs \{collapsed_y}")
  assert_true(expanded_y > head_y + 18.0, msg="expanded text opens in a card below header: \{expanded_y} vs \{head_y}")
  t.tap_text(long_line)
  t.run_for(@ui.move_most_ms)
  let (_, shut_y, _, shut_h) = t.rect_of(long_line).unwrap()
  assert_true(shut_h <= 20.0 && (shut_y - collapsed_y).abs() < 0.5, msg="shut again, one line where it was: \{shut_y} \{shut_h}")
  assert_true(t.rect_of(long_detail) is None)
  // (on a wider desktop panel where single-line long_line fits on one line, it omits the fold button so tapping does not toggle a no-op state)
  let single_long_item : Json = {
    "body": {
      "kind": "text",
      "content": {
        "text": Json::string(long_line),
        "line": Json::string(long_line),
        "md": [["p", [Json::string(long_line)]]],
        "subagent": false,
      },
    },
  }
  let wide_t = @ui.Tester::new(fn(c) { @sf.begin(c) |> ignore }, w=760.0, h=300.0, tree=fn(root) {
    @ui.set_tree_theme(@sf.ui_theme_now)
    let tips = @sf.TipLayer::new(fn() { Some(root) })
    root.lines_up(Is(None)) |> ignore
    steps_box_node(root, steps_row_first, fn(v) { item_node(v, src, "ws1/st1", "s-c1", "wide-long", Some(single_long_item), false, tips) })
  })
  wide_t.draw()
  wide_t.tap_text(long_line)
  wide_t.run_for(@ui.move_most_ms)
  assert_true(!steps_own.opened.contains("wide-long/text"), msg="single-line text that fits on one line at room width is not expandable")
  steps_reset()
}

///|
test "history group thought keeps first-line summary steady when expanded and empty Read omits dead chevron" {
  let first = "行高先按估计值占位（摘要）"
  let full = "行高先按估计值占位，滚过一次就记住实测高度。"
  let item : Json = {
    "body": {
      "kind": "group",
      "content": {
        "summary": "读取 1 个文件",
        "failures": 0,
        "pending": 0,
        "rows": [
          {
            "kind": "step",
            "content": { "name": "Read", "said": "", "hint": "src/list.ts", "meta": "40 行", "call": "{}", "failed": false },
          },
          {
            "kind": "thought",
            "content": {
              "first": Json::string(first),
              "text": Json::string(full),
              "md": [["p", [Json::string(full)]]],
              "brief": false,
            },
          },
        ],
      },
    },
  }
  steps_reset()
  @sf.set_words(@sfbase.fill)
  let src = @sffixture.fixture("history")
  let t = @ui.Tester::new(fn(c) { @sf.begin(c) |> ignore }, w=480.0, h=300.0, tree=fn(root) {
    @ui.set_tree_theme(@sf.ui_theme_now)
    let tips = @sf.TipLayer::new(fn() { Some(root) })
    root.lines_up(Is(None)) |> ignore
    steps_box_node(root, steps_row_first, fn(v) {
      item_node(v, src, "ws1/st1", "s-c1", "g1", Some(item), false, tips)
    })
  })
  t.draw()
  t.tap_text("读取 1 个文件")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.all(Button).length(), 2, msg="only group header and expandable thought are buttons; empty-result Read omits dead chevron")
  let first_y = t.rect_of(first).unwrap().1
  assert_true(t.rect_of(full) is None)
  t.tap_text(first)
  t.run_for(@ui.move_most_ms)
  assert_true((t.rect_of(first).unwrap().1 - first_y).abs() < 1.0, msg="summary preview stays steady on header row")
  assert_true(t.rect_of(full).unwrap().1 > first_y + 18.0, msg="full thought opens in card below header")
  steps_reset()
}

///|
test "history tool step renders borderless dispatch block, full-width stacked long fields, and result section header" {
  let msg = "All 4 review findings are valid (`src/sf/markdown.mbt`):\n1. Reset core_parsed[text] when re-measuring;\n2. Copy Markdown table cells cleanly;\n3. Render full-width Markdown blocks;\n4. Suppress delivery ack noise.\n5. Remove horizontal divider lines.\n6. Align inline prose fields.\n7. Gate full-screen reader button on long blocks.\n8. Keep target navigation pill.\n9. Re-run native tests.\n10. Update screenshots.\nPlease fix all 4 and re-verify."
  let sum = "Tell verifier all 4 findings are valid, ask to fix all"
  let call_json = "{\"to\":\"a036720bc24844903\",\"message\":\"All 4 review findings are valid\",\"summary\":\"Tell verifier all 4 findings are valid, ask to fix all\"}"
  let res_json = "{\"status\":\"pending_approval\"}"
  let item : Json = {
    "body": {
      "kind": "group",
      "content": {
        "summary": "读取 1 个文件 · 共 2 步",
        "failures": 0,
        "pending": 0,
        "rows": [
          {
            "kind": "step",
            "content": {
              "name": "SendMessage",
              "said": Json::string(sum),
              "hint": "",
              "meta": "",
              "call": Json::string(call_json),
              "result": Json::string(res_json),
              "failed": false,
            },
          },
        ],
      },
    },
  }
  steps_reset()
  @sf.set_words(@sfbase.fill)
  let src = @sffixture.fixture("history")
  let ask : Map[String, Json] = {
    "name": Json::string("SendMessage"),
    "call": Json::string(call_json),
    "failed": Json::boolean(false),
    "said": Json::boolean(true),
    "result": Json::string(res_json),
  }
  let tk = "g-send/group/0\u{1}" + Json::object(ask).stringify()
  steps_own.tools[tk] = {
    "call": [
      {
        "kind": "markdown",
        "target": "verifier",
        "targetId": "a036720bc24844903",
        "text": Json::string(msg),
        "md": [["p", ["All 4 review findings are valid (", ["code", "src/sf/markdown.mbt"], "). Please fix all 4."]]],
      },
    ],
    "result": [
      {
        "kind": "fields",
        "rows": [
          { "key": "status", "value": "pending_approval", "form": "short" },
        ],
      },
    ],
  }
  for case in [(390.0, 2), (900.0, 0)] {
    let (w, platform) = case
    @sf.presenters_reset()
    steps_own.opened["g-send/group"] = true
    steps_own.opened["g-send/group/0"] = true
    let t = @ui.Tester::new(
      fn(c) {
        @sf.begin(c) |> ignore
        c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
      },
      w~,
      h=600.0,
      platform~,
      tree=fn(root) {
        @ui.set_tree_theme(@sf.ui_theme_now)
        let tips = @sf.TipLayer::new(fn() { Some(root) })
        root.lines_up(Is(None)) |> ignore
        steps_box_node(root, steps_row_first, fn(v) {
          item_node(v, src, "ws1/st1", "s-c1", "g-send", Some(item), false, tips)
        })
        @sf.presented_nodes(root)
      },
    )
    t.draw()
    assert_true(t.rect_of("代理") is Some(_), msg="SendMessage shows 代理 badge")
    assert_true(t.rect_of("→ verifier") is Some(_), msg="dispatch block shows resolved target badge")
    assert_true(t.rect_of("返回") is Some(_), msg="result section header is shown")
    assert_true(t.rect_of("pending_approval") is Some(_), msg="result fields are shown")
    assert_true(t.rect_of("展开 ·") is None, msg="10-line dispatch message is not redundantly folded inside an expanded step")
    assert_eq(t.corner_faults(), [])
    assert_eq(t.lit_all_faults(), [])
    t.tap_text("全屏查看")
    t.run_for(@ui.move_most_ms * 2.0)
    assert_true(t.rect_of("复制") is Some(_), msg="reader drawer shows 复制 button")
    assert_eq(t.corner_faults(), [])
    assert_eq(t.lit_all_faults(), [])
  }
  @sf.presenters_reset()
  steps_reset()
}

///|
test "reused history rows strip i/ prefix when expanding groups and messages" {
  steps_reset()
  @sf.set_words(@sfbase.fill)
  let src = @sffixture.fixture("history")
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    w=900.0,
    h=700.0,
    platform=0,
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      history_steps_node(root, src, "ws1/st1", "s-c1", tips)
    },
  )
  t.draw()
  t.draw()
  assert_eq(t.corner_faults(), [])
  assert_eq(t.lit_all_faults(), [])
  let group_summary = "读取 3 个文件 · 跑 1 条命令"
  if t.rect_of(group_summary) is Some(_) {
    t.tap_text(group_summary)
    t.run_for(@ui.move_most_ms)
    assert_true(steps_own.opened.length() > 0, msg="tapping group header in history_steps_node opens the group")
    for k, _ in steps_own.opened {
      assert_true(!k.has_prefix("i/"), msg="opened key must not retain i/ prefix: \{k}")
    }
    assert_eq(t.corner_faults(), [])
    assert_eq(t.lit_all_faults(), [])
  }
  steps_reset()
}

///|
test "rail_shapes draws one straight line at x=4 from the icon down" {
  let c = 0x000000FFL
  // On to the next event: from the icon's bottom to the next icon, past any body
  assert_eq(rail_shapes(20.0, 0.0, true, c), [@ui.shape_of([([4.0, 20.0, 4.0, 30.0], false)], stroke=c, width=1.25)])
  assert_eq(rail_pts(20.0, 80.0, true), [4.0, 20.0, 4.0, 110.0])
  assert_eq(rail_pts(44.0, 0.0, true), [4.0, 20.0, 4.0, 54.0])
  // Last event without a body: no rail
  assert_eq(rail_shapes(20.0, 0.0, false, c).length(), 0)
  assert_eq(rail_shapes(44.0, 2.0, false, c).length(), 0)
  // Last event with a body: down beside it, 2px short of its end
  assert_eq(rail_pts(20.0, 80.0, false), [4.0, 20.0, 4.0, 98.0])
  assert_eq(rail_pts(18.0, 3.0, false), [4.0, 20.0, 4.0, 21.0])
}

///|
test "history turn divider shows deduplicated time only, breaks rail on silent turn, and measures proportional width" {
  let limit_line = "You've hit your Fable limit · resets Nov 20, 08:00"
  let items : Array[Json] = [
    {
      "key": "t1",
      "entries": [0, 0],
      "turn": { "time": "11/14 17:10" },
      "body": {
        "kind": "received",
        "content": {
          "note": "",
          "tasks": [{ "text": "子 agent 失败：group: accounts on the page", "agent": true, "failed": true }],
          "messages": [],
        },
      },
    },
    {
      "key": "t1-txt",
      "entries": [1, 1],
      "work": true,
      "body": {
        "kind": "text",
        "content": { "line": Json::string(limit_line), "text": Json::string(limit_line), "subagent": false },
      },
    },
    {
      "key": "t2",
      "entries": [2, 2],
      "turn": {},
      "body": {
        "kind": "received",
        "content": {
          "note": "",
          "tasks": [{ "text": "子 agent 失败：Review base-bind change", "agent": true, "failed": true }],
          "messages": [],
        },
      },
    },
    {
      "key": "t3",
      "entries": [3, 3],
      "turn": { "time": "17:23" },
      "body": {
        "kind": "received",
        "content": { "note": "Your turn ended without a state.", "tasks": [], "messages": [] },
      },
    },
  ]
  let hist : Json = { "items": Json::array(items), "live": [], "edge": "已到会话开头", "empty": false, "loaded": true, "more": false }
  let (_, rows) = steps_rows_of(Some(hist), items, false)
  assert_eq(rows.length(), 5)
  guard rows[2] is Item(_, cont1) else { fail("expected Item at index 2") }
  assert_eq(cont1, false, msg="empty turn {} still breaks the previous turn's vertical rail")
  guard rows[3] is Item(_, cont2) else { fail("expected Item at index 3") }
  assert_eq(cont2, false, msg="timed turn breaks the previous turn's vertical rail")
  assert_true(steps_row_shape(Some(rows[1])) != steps_row_shape(Some(rows[3])), msg="timed turn and deduplicated turn have distinct reuse shapes")

  steps_reset()
  @sf.set_words(@sfbase.fill)
  let base_src = @sffixture.fixture("history")
  let src : @sfbase.Source = {
    ..base_src,
    topic_read: fn(name, params) {
      if name == "history" {
        { value: Some(hist), error: None, version: 1 }
      } else {
        (base_src.topic_read)(name, params)
      }
    },
    topic_keyed: fn(name, params, fld, keys) {
      if name == "history" {
        None
      } else {
        (base_src.topic_keyed)(name, params, fld, keys)
      }
    },
  }
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    w=390.0,
    h=700.0,
    platform=2,
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      history_steps_node(root, src, "ws1/st1", "s-c1", tips)
    },
  )
  t.draw()
  t.draw()
  assert_true(t.rect_of("11/14 17:10") is Some(_), msg="first turn time is shown")
  assert_true(t.rect_of("17:23") is Some(_), msg="later turn time (>= 5 min) is shown")
  assert_true(t.rect_of("未发消息") is None, msg="redundant silent summary is gone")
  t.tap_text(limit_line)
  t.run_for(@ui.move_most_ms)
  assert_true(!steps_own.opened.contains("t1-txt/text"), msg="50-char proportional English line fits in 390px phone room without chevron")
  assert_eq(t.corner_faults(), [])
  assert_eq(t.lit_all_faults(), [])
  steps_reset()
}

///|
test "sent messages, received messages, and long turn-state reasons share stationary header fold toggles and 20pt first-line alignment" {
  steps_reset()
  @sf.set_words(@sfbase.fill)
  let base_src = @sffixture.fixture("history")
  let long_post = "第一行发送摘要\n第二行关键改动\n第三行风险核对\n第四行回归测试\n第五行截图对比\n第六行等待确认\n第七行补充说明"
  let long_recv = "收到第一行说明\n收到第二行背景\n收到第三行日志\n收到第四行要求\n收到第五行补充\n收到第六行截止"
  let long_done = "标记为已完成：已完成所有历史条目的收起与展开统一，并核对全部图标和首行文字严格水平对齐，无嵌套折叠按钮"
  let items : Array[Json] = [
    {
      "key": "m-in",
      "entries": [0, 0],
      "turn": { "time": "11/15 23:30" },
      "body": {
        "kind": "received",
        "content": {
          "note": "",
          "tasks": [],
          "messages": [
            {
              "key": "m0",
              "from": { "name": "Zijian Zuo", "bound": false },
              "place": { "name": "执行历史工具调用展示优化", "surface": "ember", "session": "s-c1" },
              "text": Json::string(long_recv),
            },
          ],
        },
      },
    },
    {
      "key": "p-out",
      "entries": [1, 1],
      "body": {
        "kind": "post",
        "content": {
          "text": Json::string(long_post),
          "md": [
            ["p", ["第一行发送摘要"]],
            ["p", ["第二行关键改动"]],
            ["p", ["第三行风险核对"]],
            ["p", ["第四行回归测试"]],
            ["p", ["第五行截图对比"]],
            ["p", ["第六行等待确认"]],
            ["p", ["第七行补充说明"]],
          ],
          "place": { "name": "执行历史工具调用展示优化", "surface": "ember", "session": "s-c1" },
          "block": false,
          "failed": false,
        },
      },
    },
    {
      "key": "k-done",
      "entries": [2, 2],
      "body": {
        "kind": "mark",
        "content": {
          "ends": "done",
          "text": Json::string(long_done),
        },
      },
    },
  ]
  let hist : Json = { "items": Json::array(items), "live": [], "edge": "已到会话开头", "empty": false, "loaded": true, "more": false }
  let src : @sfbase.Source = {
    ..base_src,
    topic_read: fn(name, params) {
      if name == "history" {
        { value: Some(hist), error: None, version: 1 }
      } else {
        (base_src.topic_read)(name, params)
      }
    },
    topic_keyed: fn(name, params, fld, keys) {
      if name == "history" {
        None
      } else {
        (base_src.topic_keyed)(name, params, fld, keys)
      }
    },
  }
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    w=390.0,
    h=844.0,
    platform=2,
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      history_steps_node(root, src, "ws1/st1", "s-c1", tips)
    },
  )
  t.draw()
  t.draw()
  // Header fragments on wrapped received header and sent header are 20pt tall (matching 20pt gutter icon)
  let recv_before = t.rect_of("收到来自").unwrap()
  let sent_to = t.rect_of("发送到").unwrap()
  assert_eq(recv_before.3, 20.0)
  assert_eq(sent_to.3, 20.0)
  // Both received (>3 lines) and post (>3 lines) have header fold toggles, and long done reason folds to 1 line
  let btns = t.all(Button, expanded=false)
  assert_true(btns.length() >= 3, msg="expected >= 3 collapsed toggles (received, post, ended), got \{btns.length()}")
  // Tapping post fold toggle keeps its header-right y coordinate unchanged while opening and shutting
  let post_btn = btns.filter(fn(b) { (b.rect.1 - sent_to.1).abs() < 2.0 })
  assert_eq(post_btn.length(), 1)
  let p_id = post_btn[0].id
  let p_y0 = post_btn[0].rect.1
  t.tap(post_btn[0].rect.0 + post_btn[0].rect.2 / 2.0, post_btn[0].rect.1 + post_btn[0].rect.3 / 2.0)
  t.run_for(@ui.move_most_ms)
  let post_after = t.all(Button, expanded=true).filter(fn(b) { b.id == p_id })
  assert_eq(post_after.length(), 1)
  assert_true((post_after[0].rect.1 - p_y0).abs() < 0.5, msg="post header toggle y stayed stationary: \{p_y0} -> \{post_after[0].rect.1}")
  // Long done mark folds to 1 line (20pt) and expands full reason on tap
  let done_rect = t.rect_of("标记为已完成").unwrap()
  assert_eq(done_rect.3, 20.0)
  t.tap(done_rect.0 + 40.0, done_rect.1 + 10.0)
  t.run_for(@ui.move_most_ms)
  assert_true(steps_own.opened.contains("k-done/mark"), msg="tapping long done mark toggles its card open")
  assert_eq(t.corner_faults(), [])
  assert_eq(t.lit_all_faults(), [])
  steps_reset()
}

///|
test "全屏查看's reader: what is longer than its room scrolls in it, its last line reached between its title and its foot" {
  for case in [(390.0, 2), (900.0, 0)] {
    let (w, platform) = case
    @sf.presenters_reset()
    let t = @ui.Tester::new(
      fn(c) {
        @sf.begin(c) |> ignore
        c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
      },
      w~,
      h=600.0,
      platform~,
      tree=fn(root) {
        @ui.set_tree_theme(@sf.ui_theme_now)
        @sf.presented_nodes(root)
      },
    )
    t.draw()
    open_tool_reader("输出", "", fn(rb) {
      for i in 0..<120 {
        @sf.words_node(rb, fn() { "第\{i}行" }, fn() { @sf.paragraph }) |> ignore
      }
    })
    t.run_for(@ui.move_most_ms * 2.0)
    // (the last line drawn whole between the title's foot and the foot's button's top)
    let shown = fn(s : String) {
      let over = t.words().filter(fn(x) { x.0 == "输出" }).map(fn(x) { x.2 + x.4 }).last().unwrap_or(0.0)
      let under = t.query(Button, label=@sf.t("common.done")).map(fn(r) { r.rect.1 }).unwrap_or(600.0)
      t.words().any(fn(x) { x.0 == s && x.2 >= over && x.2 + x.4 <= under })
    }
    assert_true(shown("第0行"), msg="\{w}: its first line at first")
    assert_true(!shown("第119行"), msg="\{w}: its last line not yet")
    guard t.query(Dialog, label="输出") is Some(d) else {
      // (on 小屏 a sheet: the wheel over its middle all the same)
      for _ in 0..<40 {
        t.wheel(w / 2.0, 400.0, 300.0)
      }
      t.run_for(@ui.move_most_ms * 2.0)
      assert_true(shown("第119行"), msg="\{w}: its last line reached")
      continue
    }
    for _ in 0..<40 {
      t.wheel(d.rect.0 + d.rect.2 / 2.0, d.rect.1 + d.rect.3 / 2.0, 300.0)
    }
    t.run_for(@ui.move_most_ms * 2.0)
    assert_true(shown("第119行"), msg="\{w}: its last line reached")
    assert_eq(t.corner_faults(), [])
  }
  @sf.presenters_reset()
}
