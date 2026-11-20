// The library's lines of a chat's list, its notice's pill, the words pressed to say them the other way, marking's
// colours and the cards over a chats' list (chat_notice_pill_node.mbt): each read out as what it is, pressed once a
// press, and nothing the audit finds.

///|
test "a line with a rule each side: its words between two rules as wide as each other" {
  let t = u5_case(fn(root) {
    root.box(fn(b) {
      b.width(Is(Some(400.0))) |> ignore
      labeled_rule_node(b, fn() { "以下为未读" }) |> ignore
      list_coming_node(b, fn() { true }) |> ignore
      list_failed_node(b, fn() { "读不到更早的消息：断开了" }) |> ignore
      list_none_node(b, fn() { "还没有消息" }) |> ignore
    })
    |> ignore
  })
  let (x, _, w, _) = t.rect_of("以下为未读").unwrap()
  // (its words in the middle of the 400 it is given)
  assert_true((x + w / 2.0 - 200.0).abs() <= 1.0, msg="\{x} \{w}")
  assert_true(t.find("读不到更早的消息：断开了") is Some(_))
  assert_true(t.find("还没有消息") is Some(_))
  assert_eq(t.audit(), [])
}

///|
test "words pressed to say them the other way: a button by them, pressed once; none and nothing to press while not shown" {
  let other = @signals.signal(false)
  let shown = @signals.signal(true)
  let t = u5_case(fn(root) {
    root.box(fn(b) {
      b.height(Is(Some(60.0))) |> ignore
      words_button_node(b, fn() { if other.get() { "11月18日 14:56" } else { "3 分钟前" } }, fn() { u5_words }, shown=fn() {
        shown.get()
      }, fn() { other.set(!other.get()) })
      |> ignore
    })
    |> ignore
  })
  t.click(Button, label="3 分钟前")
  t.draw()
  assert_true(t.find("11月18日 14:56") is Some(_))
  assert_eq(t.audit(), [])
  shown.set(false)
  t.draw()
  assert_true(t.find("11月18日 14:56") is None)
  assert_eq(t.all(Button, label="11月18日 14:56").length(), 0)
  assert_eq(t.all(Button).filter(fn(s) { s.label == "" }).map(fn(s) { s.disabled }), [true])
  assert_eq(t.audit(), [])
}

///|
test "a notice's pill: a disclosure by its words, open as it is pressed, ×n after them, its action pressed apart" {
  let open = @signals.signal(false)
  let acted = Ref(0)
  let t = u5_case(fn(root) {
    root.box(fn(b) {
      b.width(Is(Some(500.0))).lines_up(Is(Some(Middle))) |> ignore
      notice_pill_node(
        b,
        fn() { "智能体出错了 ×3" },
        fn() { open.get() },
        fn() { true },
        fn() { 3 },
        fn() { open.set(!open.get()) },
        fn(room) { words_node(room, fn() { "智能体出错了" }, fn() { u5_words }) |> ignore },
        end=fn(line, strut) {
          notice_end_action_node(line, fn() { "重试" }, fn() { true }, fn() { false }, fn() { acted.val += 1 }, strut~)
          |> ignore
        },
        detailed=fn() { true },
        detail=fn(d) { words_node(d, fn() { "rate limited" }, fn() { u5_words }) |> ignore },
      )
      |> ignore
    })
    |> ignore
  })
  assert_true(t.find("×3") is Some(_))
  assert_true(t.find("rate limited") is None)
  assert_eq(t.all(Button, expanded=false).map(fn(s) { s.label }), ["智能体出错了 ×3"])
  t.click(Button, label="智能体出错了 ×3")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("rate limited") is Some(_))
  assert_eq(t.all(Button, expanded=true).length(), 1)
  t.click(Button, label="重试")
  t.draw()
  assert_eq(acted.val, 1)
  assert_eq(open.get(), true)
  assert_eq(t.audit(), [])
}

///|
test "marking's colours: one radio group, the one chosen checked, another picked by a press" {
  let chosen = @signals.signal(0xE5704AFFL)
  let t = u5_case(fn(root) {
    root.box(fn(row) {
      row.row(Is(true)).gap(Is(2.0)) |> ignore
      color_swatches_node(row, fn() { "颜色" }, [(0xE5704AFFL, "颜色 1"), (0x3E7BFAFFL, "颜色 2")], fn() { chosen.get() }, fn(c) {
        chosen.set(c)
      })
    })
    |> ignore
  })
  assert_eq(t.all(RadioGroup, label="颜色").length(), 1)
  assert_eq(t.all(Radio, checked=On).map(fn(s) { s.label }), ["颜色 1"])
  t.click(Radio, label="颜色 2")
  t.draw()
  assert_eq(chosen.get(), 0x3E7BFAFFL)
  assert_eq(t.all(Radio, checked=On).map(fn(s) { s.label }), ["颜色 2"])
  assert_eq(t.audit(), [])
}

///|
test "a card over a chats' list: pressed whole, its × apart" {
  let opened = Ref(0)
  let gone = Ref(0)
  let tips_at : Ref[@view.View?] = Ref(None)
  let tips = TipLayer::new(fn() { tips_at.val })
  let t = u5_case(fn(root) {
    root.box(fn(b) {
      b.width(Is(Some(360.0))) |> ignore
      news_card_node(
        b,
        "sparks",
        fn() { "已更新到 1389" },
        fn() { "已更新到 1389 新增：对话页" },
        fn() { opened.val += 1 },
        fn(w) { words_node(w, fn() { "新增：对话页" }, fn() { news_card_line }) |> ignore },
        close=(tips, fn() { "不再显示" }, fn() { gone.val += 1 }),
      )
      |> ignore
    })
    |> ignore
    tips_at.val = Some(root.box(fn(l) { l.over(Is(true)) |> ignore }))
  })
  t.click(Button, label="已更新到 1389 新增：对话页")
  t.click(Button, label="不再显示")
  t.draw()
  assert_eq((opened.val, gone.val), (1, 1))
  assert_eq(t.audit(), [])
}
