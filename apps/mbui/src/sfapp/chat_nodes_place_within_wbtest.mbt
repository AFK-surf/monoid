// Going to something low in a long message on a chat's page made as nodes (sfbase's chat_page_nodes) brings it before
// the eyes and shows what was meant (the chat's sixth principle): a quote's passage, a search's words, deep in an
// agent's long answer (the fixture's long_reply, its last line), come to rest between the bar and the composer, not
// only the message's top under the bar with what was meant under the composer (ListPlace::bring's `sought`,
// View::sought). 小屏's search from Home is search_wbtest's; here a quote's card's go-to on 小屏 and 大屏 and a
// search's on 大屏.

///|
/// Where the line holding `words` is drawn, its top and foot.
fn place_within_line(t : @ui.Tester, words : String) -> (Double, Double)? {
  t.text_runs().iter().find_first(fn(r) { r.text.contains(words) }).map(fn(r) { (r.top, r.bottom) })
}

///|
test "a quote's passage low in a long message, gone to on a chat's page made as nodes, 小屏 and 大屏: brought between the bar and the composer, lit there" {
  for s in [("小屏", 390.0, 844.0, 2), ("大屏", 1280.0, 800.0, 0)] {
    let (name, w, h, platform) = s
    let (t, _) = chat_nodes_calling(w, h, platform, [])
    let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
    // (as a quote's card pressed goes there: message_quotes_node's press, in its handler's change)
    @signals.start_batch()
    @sfbase.go_to(r, 3.0, passage="有问题随时说")
    @signals.end_batch()
    t.run_for(@sfbase.flash_in_ms + (@sfbase.flash_held_ms - @sfbase.flash_in_ms) / 2.0)
    guard place_within_line(t, "有问题随时说") is Some((top, foot)) else { fail("\{name}: the passage not drawn") }
    guard composer_top(t) is Some(under) else { fail("\{name}: no composer") }
    assert_true(top > 120.0 && foot < under, msg="\{name}: the passage at \{top}…\{foot}, the composer at \{under}")
    // (lit, as a passage picked is: the accent's ground over its words)
    let lit = grounds_in(t, @sf.theme().p.accent).filter(fn(g) { g.1 < foot && g.1 + g.3 > top })
    assert_true(lit.length() >= 1, msg="\{name}: the passage not lit")
  }
}

///|
test "a search's words low in a long message, the chat opened at it on a chat's page made as nodes, 大屏: brought between the bar and the composer, stroked there" {
  let (t, _) = chat_nodes_calling(1280.0, 800.0, 0, [])
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  @sfbase.open_chat_found(r, 3.0, ["有问题随时说"])
  t.run_for(@sfpages.found_draw_ms)
  guard place_within_line(t, "有问题随时说") is Some((top, foot)) else { fail("the match not drawn") }
  guard composer_top(t) is Some(under) else { fail("no composer") }
  assert_true(top > 120.0 && foot < under, msg="the match at \{top}…\{foot}, the composer at \{under}")
  assert_true(search_stroke_under(t, "有问题随时说", @sf.theme().p.accent, @sf.message_stroke.width))
}

///|
/// The chat these go-tos are in (the fixture's s-c1).
let place_within_ref : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }

///|
/// Chat s-c1 gone to its message `seq` (the passage `passage` of it) as a press goes there (in its handler's change),
/// and let be till its flash has gone.
fn place_within_go(t : @ui.Tester, seq : Double, passage? : String = "") -> Unit {
  @signals.start_batch()
  @sfbase.go_to(place_within_ref, seq, passage~)
  @signals.end_batch()
  t.run_for(@sfbase.flash_ms)
}

///|
/// Paragraphs `n` of a long message, each saying which it is (`said`: what it is about).
fn place_within_paras(n : Int, said : String) -> Array[String] {
  Array::makei(n, fn(i) { "\{said}第\{i + 1}段：这一段讲清单里的一项，写得长一些，好让一屏放不下整条消息的所有段落。" })
}

///|
test "a message gone to on a chat's page made as nodes, 小屏 and 大屏: what is read in it as far under the bar whether it is joined to the one before or apart from it, as the list's first row's, and it where the core is told the reader is" {
  for s in [("小屏", 390.0, 844.0, 2), ("大屏", 1280.0, 800.0, 0)] {
    let (name, w, h, platform) = s
    let calls : Array[(String, Json)] = []
    let (t, _) = chat_nodes_calling(w, h, platform, calls)
    // (two of the viewer's own: one joined to the one before it, one apart from it, the notice before it)
    place_within_go(t, 7.0)
    guard place_within_line(t, "还有深色模式也看一下") is Some((joined, _)) else { fail("\{name}: 7 not drawn") }
    // (where the reader is, told the core: the one gone to, not the one over it whose tail shows in the room under the
    // bar)
    let placed = calls.filter(fn(c) { c.0 == "chat.place" })
    assert_true(placed.length() > 0, msg="\{name}: no place told")
    assert_eq(number(Some(placed[placed.length() - 1].1), "seq"), 7.0, msg="\{name}: \{Repr(placed.map(fn(c) { c.1.stringify() }))}")
    place_within_go(t, 2.0)
    guard place_within_line(t, "帮我把聊天页的列表做成虚拟列表") is Some((apart, _)) else { fail("\{name}: 2 not drawn") }
    assert_true((joined - apart).abs() < 0.5, msg="\{name}: joined at \{joined}, apart at \{apart}")
    // (under the bar by the list's room, not the room over the message's block more)
    guard composer_top(t) is Some(_) else { fail("\{name}: no composer") }
    assert_true(apart > 0.0 && apart < h / 3.0, msg="\{name}: at \{apart}")
  }
}

///|
test "a message gone to on a chat's page made as nodes stands there while new messages arrive at the list's foot: the page before not asked, the one gone to not moved; moved by the reader, the page before asked and what it lit let go of" {
  for s in [("小屏", 390.0, 844.0, 2), ("大屏", 1280.0, 800.0, 0)] {
    let (name, w, h, platform) = s
    let calls : Array[(String, Json)] = []
    let came = @signals.signal(0)
    let (t, _) = chat_nodes_calling(w, h, platform, calls, came~)
    place_within_go(t, 2.0)
    let words = "帮我把聊天页的列表做成虚拟列表"
    guard place_within_line(t, words) is Some((at, _)) else { fail("\{name}: 2 not drawn") }
    calls.clear()
    // (new messages arriving at the foot: what is in sight told again each time)
    for i in 1..=3 {
      @ui.came_from_outside()
      came.set(i)
      t.run_for(@ui.move_most_ms)
    }
    assert_eq(calls.filter(fn(c) { c.0 == "chat.older" }).length(), 0, msg="\{name}: the page before asked as it stands")
    assert_eq(place_within_line(t, words).map(fn(l) { l.0 }), Some(at), msg="\{name}: moved")
    let rd = @sfbase.reading_of(place_within_ref.station + "\u{1}" + place_within_ref.session)
    assert_eq(rd.flash, "ts2", msg=name)
    // (the reader's wheel: theirs from then)
    t.move_to(w / 2.0, h / 2.0)
    t.wheel(w / 2.0, h / 2.0, -40.0)
    t.run_for(@ui.move_most_ms)
    assert_true(calls.filter(fn(c) { c.0 == "chat.older" }).length() >= 1, msg="\{name}: the page before not asked once read up")
    assert_eq(rd.flash, "", msg="\{name}: what it lit still where the reader is")
  }
}

///|
test "a quote's passage low in a long message in sight already, gone to on a chat's page made as nodes, 大屏: glided to between the bar and the composer" {
  let (t, _) = chat_nodes_calling(1280.0, 800.0, 0, [])
  // (its top in sight first)
  place_within_go(t, 3.0)
  guard place_within_line(t, "列表改成虚拟列表") is Some(_) else { fail("its top not drawn") }
  @signals.start_batch()
  @sfbase.go_to(place_within_ref, 3.0, passage="有问题随时说")
  @signals.end_batch()
  t.run_for(@sfbase.flash_in_ms + (@sfbase.flash_held_ms - @sfbase.flash_in_ms) / 2.0)
  guard place_within_line(t, "有问题随时说") is Some((top, foot)) else { fail("the passage not drawn") }
  guard composer_top(t) is Some(under) else { fail("no composer") }
  assert_true(top > 120.0 && foot < under, msg="the passage at \{top}…\{foot}, the composer at \{under}")
}

///|
test "a long message drawn a block a piece, on a chat's page made as nodes, 小屏 and 大屏: a quote's passage in a piece far down it and a search's words there each brought between the bar and the composer, lit and stroked there" {
  for s in [("小屏", 390.0, 844.0, 2), ("大屏", 1280.0, 800.0, 0)] {
    let (name, w, h, platform) = s
    let search = name == "大屏"
    let paras = place_within_paras(30, "")
    let long = @signals.signal([(3.0, paras)])
    let (t, _) = chat_nodes_calling(w, h, platform, [], long~)
    let line = "第25段：这一段讲清单里的一项"
    @signals.start_batch()
    @sfbase.go_to(place_within_ref, 3.0, passage=line)
    @signals.end_batch()
    t.run_for(@sfbase.flash_in_ms + (@sfbase.flash_held_ms - @sfbase.flash_in_ms) / 2.0)
    guard place_within_line(t, line) is Some((top, foot)) else { fail("\{name}: the passage not drawn") }
    guard composer_top(t) is Some(under) else { fail("\{name}: no composer") }
    assert_true(top > 60.0 && foot < under, msg="\{name}: the passage at \{top}…\{foot}, the composer at \{under}")
    let lit = grounds_in(t, @sf.theme().p.accent).filter(fn(g) { g.1 < foot && g.1 + g.3 > top })
    assert_true(lit.length() >= 1, msg="\{name}: the passage not lit")
    // (a search's words in that piece: the chat opened at it, the words stroked where they are; 小屏's search from Home
    // is search_wbtest's, a page of its own)
    guard search else { continue }
    @sfbase.open_chat_found(place_within_ref, 3.0, ["第27段"])
    t.run_for(@ui.move_most_ms)
    t.run_for(@sfpages.found_draw_ms)
    guard place_within_line(t, "第27段") is Some((top, foot)) else { fail("\{name}: the match not drawn") }
    assert_true(top > 60.0 && foot < under, msg="\{name}: the match at \{top}…\{foot}, the composer at \{under}")
    assert_true(search_stroke_under(t, "第27段", @sf.theme().p.accent, @sf.message_stroke.width), msg="\{name}: not stroked")
  }
}

///|
test "the bell to what waits to be decided under a long message drawn a block a piece, on a chat's page made as nodes, 小屏 and 大屏: pressed, what it asks brought between the bar and the composer, not the message's top" {
  for s in [("小屏", 390.0, 844.0, 2), ("大屏", 1280.0, 800.0, 0)] {
    let (name, w, h, platform) = s
    let long = @signals.signal([(8.0, place_within_paras(30, "截图"))])
    let (t, _) = chat_nodes_calling(w, h, platform, [], long~)
    // (read up past it, so that its ask is out of sight)
    place_within_go(t, 2.0)
    t.click(Button, label=@sf.t("web-main.chat.asks.go"))
    t.run_for(@sfbase.flash_ms)
    guard place_within_line(t, "先不换") is Some((top, foot)) else { fail("\{name}: its ask not drawn") }
    guard composer_top(t) is Some(under) else { fail("\{name}: no composer") }
    assert_true(top > 60.0 && foot < under, msg="\{name}: its ask at \{top}…\{foot}, the composer at \{under}")
  }
}

///|
test "a long message edited into more pieces at the list's foot, on a chat's page made as nodes, 小屏 and 大屏: followed no further than its top, which stays in sight" {
  for s in [("小屏", 390.0, 844.0, 2), ("大屏", 1280.0, 800.0, 0)] {
    let (name, w, h, platform) = s
    let came = @signals.signal(0)
    let long = @signals.signal([])
    let (t, _) = chat_nodes_calling(w, h, platform, [], came~, long~, said=true)
    // (a message arriving at the foot as the list rests there, then edited in place into more and more paragraphs)
    @ui.came_from_outside()
    long.set([(12.0, place_within_paras(1, "长文"))])
    came.set(1)
    t.run_for(@ui.move_most_ms)
    let first = "长文第1段"
    // (a paragraph more at a time, each a piece more)
    for n in 2..=16 {
      @ui.came_from_outside()
      long.set([(12.0, place_within_paras(n, "长文"))])
      t.run_for(@ui.move_most_ms)
      guard place_within_line(t, first) is Some((top, _)) else { fail("\{name}: its top gone with \{n} paragraphs") }
      assert_true(top > 40.0, msg="\{name}: its top at \{top} with \{n} paragraphs")
    }
  }
}
