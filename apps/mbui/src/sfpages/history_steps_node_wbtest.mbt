// A reminder in an agent's history: its label stays readable beside a long first line, and its whole text opens below.

///|
test "a web call's history row names the tool and the pages opened" {
  for case in [("zh", "联网", "打开 2 个网页"), ("en", "Web", "Opening 2 web pages")] {
    let (lang, label, said) = case
    for w in [390.0, 900.0] {
      steps_reset()
      @sf.set_words(@sfbase.fill)
      let src = @sffixture.fixture("history")
      let step : Json = {
        "name": "WebSearch",
        "said": Json::string(said),
        "hint": "",
        "meta": "",
        "call": "{\"open\":[{\"ref_id\":\"turn8search2\"},{\"ref_id\":\"turn6search1\"}]}",
        "result": "",
        "failed": false,
      }
      let t = @ui.Tester::new(fn(c) { @sf.begin(c) |> ignore }, w~, h=160.0, env=[("MBUI_LOCALE", lang)], tree=fn(root) {
        @ui.set_tree_theme(@sf.ui_theme_now)
        root.box(fn(v) { step_node(v, src, "ws1/st1", "s-c1", "web", Some(step)) }) |> ignore
      })
      t.draw()
      assert_true(t.rect_of(label) is Some(_), msg="\{lang}, \{w}: web tool label")
      assert_true(t.rect_of(said) is Some(_), msg="\{lang}, \{w}: page count")
      assert_eq(t.audit(), [])
    }
  }
  steps_reset()
}

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
  assert_true(steps_row_shape(Some(rows[1]), "ws1/st1", "s-c1") != steps_row_shape(Some(rows[3]), "ws1/st1", "s-c1"), msg="timed turn and deduplicated turn have distinct reuse shapes")

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
  assert_true(!steps_own.opened.contains(steps_item_key("ws1/st1", "s-c1", "t1-txt") + "/text"), msg="50-char proportional English line fits in 390px phone room without chevron")
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
  assert_true(steps_own.opened.contains(steps_item_key("ws1/st1", "s-c1", "k-done") + "/mark"), msg="tapping long done mark toggles its card open")
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

///|
test "opening a record reads the selected session even when two histories use the same entry numbers" {
  steps_reset()
  @sf.set_words(@sfbase.fill)
  let base = @sffixture.fixture("history")
  let reads : Array[String] = []
  let tester = fn(station : String, key : String, name : String) {
    let row : Json = {
      "kind": "step",
      "content": { "name": "Read", "said": Json::string(name), "call": "{}", "brief": true, "entries": [1, 2] },
    }
    let history : Json = {
      "items": [{ "key": "e1", "entries": [1, 2], "body": { "kind": "group", "content": {
        "summary": Json::string("读取文件组 " + key), "rows": [row],
      } } }], "edge": "", "loaded": true, "more": false,
    }
    let src : @sfbase.Source = {
      ..base,
      topic_read: fn(n, params) {
        if n == "history" { { value: Some(history), error: None, version: 1 } } else { (base.topic_read)(n, params) }
      },
      topic_keyed: fn(_, _, _, _) { None },
      call: fn(n, params, reply) {
        if n == "history.detail" {
          reads.push(text(Some(params), "station") + "/" + text(Some(params), "key"))
          reply(Ok(Json::null()))
        } else {
          (base.call)(n, params, reply)
        }
      },
    }
    @ui.Tester::new(fn(c) { @sf.begin(c) |> ignore }, tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      history_steps_node(root, src, station, key, tips)
    }, w=390.0, h=700.0, platform=2)
  }
  for (station, key, name) in [("ws/st1", "a", "alpha.mbt"), ("ws/st1", "b", "beta.mbt"), ("ws/st2", "a", "gamma.mbt")] {
    let t = tester(station, key, name)
    t.draw()
    assert_true(t.rect_of(name) is None, msg="another history's row was expanded in " + name)
    t.tap_text("读取文件组 " + key)
    t.run_for(@ui.move_most_ms)
    t.tap_text(name)
    t.run_for(@ui.move_most_ms)
    assert_eq(reads.last(), Some(station + "/" + key))
  }
  steps_reset()
}

///|
test "a record stays open on its own output when an earlier step is inserted" {
  steps_reset()
  @sf.set_words(@sfbase.fill)
  let base = @sffixture.fixture("history")
  let src : @sfbase.Source = {
    ..base,
    call: fn(n, params, reply) {
      if n == "history.tool" {
        reply(Ok({ "call": [], "result": [{ "kind": "output", "text": Json::string(text(Some(params), "result")) }] }))
      } else {
        (base.call)(n, params, reply)
      }
    },
  }
  let row = fn(entry : Int, name : String, result : String) -> Json {
    { "kind": "step", "content": {
      "name": "Bash", "said": Json::string(name), "result": Json::string(result),
      "entries": [Json::number(entry.to_double()), Json::number((entry + 1).to_double())],
    } }
  }
  let earlier = row(2, "检查配置", "配置存在")
  let selected = row(4, "检查版本", "版本一致")
  let rows = @signals.signal([selected])
  let t = @ui.Tester::new(fn(c) { @sf.begin(c) |> ignore }, tree=fn(root) {
    @ui.set_tree_theme(@sf.ui_theme_now)
    group_rows_each_node(root, src, "ws/st1", "b", fn() { "test group" }, fn() { rows.get() })
  }, w=390.0, h=560.0, platform=2)
  t.draw()
  t.tap_text("检查版本")
  t.run_for(@ui.move_most_ms)
  assert_true(t.rect_of("版本一致") is Some(_))
  rows.set([earlier, selected])
  t.run_for(@ui.move_most_ms)
  assert_true(t.rect_of("版本一致") is Some(_), msg="the selected step still shows its output")
  assert_true(t.rect_of("配置存在") is None, msg="the preceding step stays closed")
  steps_reset()
}

///|
test "tool step failure shows retry, copy works, and brief detail retries after close" {
  steps_reset()
  @sf.set_words(@sfbase.fill)
  let base = @sffixture.fixture("history")
  let tool_calls = Ref(0)
  let detail_calls = Ref(0)
  let src : @sfbase.Source = {
    ..base,
    call: fn(n, _params, reply) {
      if n == "history.tool" {
        tool_calls.val = tool_calls.val + 1
        if tool_calls.val == 1 {
          reply(Err({ "message": "parse timeout" }))
        } else {
          reply(Ok({
            "call": [{ "kind": "code", "text": "echo hello_world", "lang": "sh" }],
            "result": [{ "kind": "output", "text": "hello_world_out" }],
          }))
        }
      } else if n == "history.detail" {
        detail_calls.val = detail_calls.val + 1
        if detail_calls.val == 1 {
          reply(Err({ "message": "offline" }))
        } else {
          reply(Ok(Json::null()))
        }
      } else {
        (base.call)(n, _params, reply)
      }
    },
  }
  let rows : Array[Json] = [
    {
      "kind": "step",
      "content": {
        "name": "Bash",
        "said": "测试工具失败",
        "call": "{\"command\":\"echo hello_world\"}",
        "result": "hello_world_out",
        "entries": [1, 2],
      },
    },
    {
      "kind": "step",
      "content": {
        "name": "Read",
        "said": "测试摘要重开",
        "brief": true,
        "entries": [3, 4],
      },
    },
  ]
  let t = @ui.Tester::new(fn(c) { @sf.begin(c) |> ignore }, tree=fn(root) {
    @ui.set_tree_theme(@sf.ui_theme_now)
    group_rows_each_node(root, src, "ws/st1", "s1", fn() { "retry-grp" }, fn() { rows })
  }, w=390.0, h=600.0, platform=2)
  t.draw()
  // 1. Non-brief step: first history.tool fails -> shows 重试 -> tap 重试 -> renders result + 复制 button
  t.tap_text("测试工具失败")
  t.run_for(@ui.move_most_ms)
  assert_eq(tool_calls.val, 1)
  assert_true(t.query(Button, label="重试") is Some(_), msg="failed history.tool must show retry button instead of infinite spinner")
  t.click(Button, label="重试")
  t.run_for(@ui.move_most_ms)
  assert_eq(tool_calls.val, 2)
  assert_true(t.rect_of("hello_world_out") is Some(_), msg="retried history.tool renders result")
  let copy_btns = t.all(Button, label="复制")
  assert_true(copy_btns.length() >= 1, msg="tool step offers quick copy")
  let cr = copy_btns[0].rect
  t.tap(cr.0 + cr.2 / 2.0, cr.1 + cr.3 / 2.0)
  t.frame()
  assert_true(t.query(Button, label="已复制") is Some(_), msg="quick copy button flips to 已复制")
  // 2. Brief step: first history.detail fails -> closing clears error -> reopening retries
  t.tap_text("测试摘要重开")
  t.run_for(@ui.move_most_ms)
  assert_eq(detail_calls.val, 1)
  assert_true(t.query(Button, label="重试") is Some(_), msg="failed history.detail shows retry")
  t.tap_text("测试摘要重开")
  t.run_for(@ui.move_most_ms)
  t.tap_text("测试摘要重开")
  t.run_for(@ui.move_most_ms)
  assert_eq(detail_calls.val, 2, msg="reopening a failed brief step retries history.detail")
  steps_reset()
}

///|
test "clip_lines_node shows bottom 查看完整内容 affordance when overflowing 14 lines" {
  steps_reset()
  @sf.set_words(@sfbase.fill)
  let lines = Array::makei(24, fn(i) { "line \{i + 1}: overflow verification text for clip_lines_node" }).join("\n")
  let t = @ui.Tester::new(fn(c) { @sf.begin(c) |> ignore }, tree=fn(root) {
    @ui.set_tree_theme(@sf.ui_theme_now)
    card_plain_or_clip_node(root, "长输出", lines, h_output, mono=true)
  }, w=340.0, h=600.0, platform=0)
  t.draw()
  t.frame()
  assert_true(t.rect_of("查看完整内容") is Some(_), msg="clipped 24-line block must show bottom 查看完整内容 strip")
  steps_reset()
}

///|
test "floating jump-to-bottom button restores auto-follow after entry jump" {
  steps_reset()
  @sf.set_words(@sfbase.fill)
  let base = @sffixture.fixture("history")
  let hist_items : Array[Json] = Array::makei(25, fn(i) {
    {
      "key": Json::string("item-\{i}"),
      "entries": [Json::number((i * 2 + 1).to_double()), Json::number((i * 2 + 2).to_double())],
      "body": {
        "kind": "received",
        "content": {
          "note": "",
          "tasks": [],
          "messages": [{ "from": { "name": "林", "bound": false }, "text": Json::string("第 \{i} 轮消息内容用于填充足够高度以触发滚动与回底按钮") }],
        },
      },
    }
  })
  let history : Json = { "items": Json::array(hist_items), "edge": "开始", "loaded": true, "more": false }
  let src : @sfbase.Source = {
    ..base,
    topic_read: fn(n, params) {
      if n == "history" { { value: Some(history), error: None, version: 1 } } else { (base.topic_read)(n, params) }
    },
    topic_keyed: fn(_, _, _, _) { None },
  }
  let t = @ui.Tester::new(fn(c) { @sf.begin(c) |> ignore }, tree=fn(root) {
    @ui.set_tree_theme(@sf.ui_theme_now)
    let tips = @sf.TipLayer::new(fn() { Some(root) })
    history_steps_node(root, src, "ws/st1", "s-jump", tips)
  }, w=360.0, h=420.0, platform=0)
  t.run_for(@ui.move_most_ms)
  let lkey = "history-steps/ws/st1/s-jump"
  // Jump to the earliest entry: sets went[lkey] and shows floating jump-to-bottom button.
  history_focus("ws/st1", "s-jump", 1)
  t.run_for(@ui.move_most_ms + 300.0)
  assert_true(steps_own.went.contains(lkey), msg="entry jump pauses auto-follow")
  let jump_btn = t.query(Button, label=@sf.t("web-main.chat.toLatest"))
  assert_true(jump_btn is Some(_), msg="floating jump-to-bottom button appears when away from foot")
  let r = jump_btn.unwrap().rect
  t.tap(r.0 + r.2 / 2.0, r.1 + r.3 / 2.0)
  t.run_for(@ui.move_most_ms + 400.0)
  assert_true(!steps_own.went.contains(lkey), msg="jumping back to bottom resumes auto-follow")
  steps_reset()
}
