// Unit tests for selected-text share image layout, Markdown context extraction, pagination, and QR encoding.

///|
test "excerpt layout: visual unit measurement and thousands formatting" {
  assert_eq(measure_excerpt_units(""), 0.0)
  assert_eq(measure_excerpt_units("陶哲轩"), 3.0)
  assert_eq(count_excerpt_chars("陶哲轩 AI 证明"), 7)
  assert_eq(format_excerpt_count(999), "999")
  assert_eq(format_excerpt_count(10000), "10,000")
  assert_eq(format_excerpt_date(1795774775027.0), "2026.11.27")
  // Local timezone crossing midnight: 2026-11-27 17:30 UTC is 2026-11-28 01:30 UTC+8.
  assert_eq(format_excerpt_date(1795800600000.0, offset_min=0), "2026.11.27")
  assert_eq(format_excerpt_date(1795800600000.0, offset_min=480), "2026.11.28")
  assert_eq(format_excerpt_date(0.0), "")
}

///|
test "excerpt layout: disambiguates duplicate sentences across paragraphs via first_before" {
  let paras = [
    "第一段开场：好的，先这样。后面还有别的事。",
    "第二段过渡内容。",
    "第三段前文铺垫。",
    "第四段总结：好的，先这样。我们明天继续。",
  ]
  let p = build_excerpt_payload(paras, "好的，先这样。", "第四段总结：", false, "重复句子测试", "2026.11.27")
  assert_true(p.before_context.contains("第四段总结："), msg="expected paragraph 4 before context, got: \{p.before_context}")
  assert_true(p.after_context.contains("我们明天继续"), msg="expected paragraph 4 after context, got: \{p.after_context}")
  // Empty first_before prefers a paragraph that starts with the needle over an earlier mid-paragraph match.
  let paras2 = [
    "前缀里也有：好的，先这样。",
    "好的，先这样。这是段首的另一处。",
  ]
  let p2 = build_excerpt_payload(paras2, "好的，先这样。", "", false, "段首优先测试", "2026.11.27")
  assert_true(p2.after_context.contains("这是段首的另一处"), msg="expected start-of-paragraph match, got: \{p2.after_context}")
}

///|
test "excerpt layout: partial multi-line match preserves all selected lines without dropping tail" {
  let paras = ["第一行原文。", "第二行原文。"]
  let p = build_excerpt_payload(paras, "第一行原文。\n未在 AST 中匹配到的表格行\n末尾补充一句", "", false, "部分匹配测试", "2026.11.27")
  assert_true(p.selected_text.contains("第一行原文。"))
  assert_true(p.selected_text.contains("未在 AST 中匹配到的表格行"))
  assert_true(p.selected_text.contains("末尾补充一句"))
  assert_eq(p.after_context, "")
}

///|
test "excerpt layout: 100k-char selection stays bounded O(N) and ZWJ emoji stays intact in fade tokens" {
  let chunk = "这是一段用于测试超长日志性能的连续中文段落内容，验证线性扫描不会在主线程卡死。"
  let parts : Array[String] = []
  for _ in 0..<2500 {
    parts.push(chunk)
  }
  let mega = parts.join("\n\n")
  let payload : ExcerptPayload = {
    before_context: "",
    before_join: Paragraph,
    selected_text: mega,
    after_context: "",
    after_join: Paragraph,
    source_title: "超长日志",
    date_label: "2026.11.27",
  }
  let p_pages = plan_excerpt_cards(payload, Pages)
  assert_eq(p_pages.cards.length(), 9)
  assert_true(p_pages.was_truncated)
  assert_true(p_pages.total_chars >= 90000)
  assert_true(p_pages.total_possible_pages > 100)
  // ZWJ emoji sequence stays in a single fade token.
  let tokens = ex_fade_tokens("前👩‍💻后")
  assert_eq(tokens.length(), 3)
  assert_eq(tokens[1], "👩‍💻")
}

///|
test "excerpt layout: extracts inline and paragraph context from Markdown AST" {
  let raw = "提到，他的一些博士生很焦虑，担心 OpenAI 或 Anthropic 可能已经在内部做出了他们手里的题。\n\n陶哲轩：理想情况下，科技公司应该在让机器自动生成证明之前，就和数学界合作。\n\n但现在的问题是，科技公司和数学界的根本激励完全不同。"
  let m = @sfbase.message_of({
    "ts": Json::string("m1"),
    "text": Json::string(raw),
    "md": Json::array([
      Json::array([Json::string("p"), Json::array([Json::string("提到，他的一些博士生很焦虑，担心 OpenAI 或 Anthropic 可能已经在内部做出了他们手里的题。")])]),
      Json::array([Json::string("p"), Json::array([Json::string("陶哲轩：理想情况下，科技公司应该在让机器自动生成证明之前，就和数学界合作。")])]),
      Json::array([Json::string("p"), Json::array([Json::string("但现在的问题是，科技公司和数学界的根本激励完全不同。")])]),
    ]),
  })
  let paras = message_plain_paragraphs(m)
  assert_eq(paras.length(), 3)
  let payload = build_excerpt_payload(
    paras,
    "ropic 可能已经在内部做出了他们手里的题。\n陶哲轩：理想情况下，科技公司应该在让机器自动生成证明之前，就和数学界合作。\n但现在的问题是，科技公司和数学界的根本激励",
    "提到，他的一些博士生很焦虑，担心 OpenAI 或 Anth",
    false,
    "整理陶哲轩访谈：AI 证明与数学界合作要点",
    "2026.11.27",
  )
  assert_eq(payload.before_join, Inline)
  assert_true(payload.before_context.has_suffix("或 Anth"))
  assert_eq(payload.after_join, Inline)
  assert_true(payload.after_context.has_prefix("完全不同"))
  assert_true(payload.selected_text.contains("\n\n"))
}

///|
test "excerpt layout: handles 10,000-char selection with single-card excerpt and 9-card cap" {
  let para = "陶哲轩指出，理想情况下科技公司应当在机器大规模产出自动证明之前就与数学界建立透明的协作规范。"
  let parts : Array[String] = []
  for _ in 0..<240 {
    parts.push(para)
  }
  let huge = parts.join("\n\n")
  assert_true(count_excerpt_chars(huge) > 10000)
  let payload : ExcerptPayload = {
    before_context: "此前在访谈中还提到过另一个相关观点。",
    before_join: Paragraph,
    selected_text: huge,
    after_context: "这是末尾未选中的补充说明。",
    after_join: Paragraph,
    source_title: "万字长文测试",
    date_label: "2026.11.27",
  }
  let p_excerpt = plan_excerpt_cards(payload, Excerpt)
  assert_true(p_excerpt.exceeds_single_limit)
  assert_true(p_excerpt.was_truncated)
  assert_eq(p_excerpt.cards.length(), 1)
  assert_true(p_excerpt.cards[0].truncated_end)
  assert_eq(p_excerpt.cards[0].after_context, "")
  assert_true(p_excerpt.total_possible_pages > 9)

  let p_pages = plan_excerpt_cards(payload, Pages)
  assert_eq(p_pages.cards.length(), 9)
  assert_true(p_pages.was_truncated)
  assert_true(p_pages.cards[0].continues_to_next)
  assert_true(!p_pages.cards[0].continued_from_prev)
  assert_true(p_pages.cards[8].continued_from_prev)
  assert_true(!p_pages.cards[8].continues_to_next)
  assert_true(p_pages.cards[8].truncated_end)
  assert_true(p_pages.shown_chars < p_pages.total_chars)
}

///|
test "excerpt qr: encodes Version 4 ECC-H matrix with valid finders, alignment, and vector shapes" {
  let q = encode_excerpt_qr("https://monoid.build")
  assert_eq(q.size, 33)
  assert_eq(q.modules.length(), 33 * 33)
  // Top-left finder corners and center.
  assert_true(q.modules[0 * 33 + 0])
  assert_true(!q.modules[1 * 33 + 1])
  assert_true(q.modules[3 * 33 + 3])
  // Alignment pattern at (26, 26).
  assert_true(q.modules[26 * 33 + 26])
  assert_true(!q.modules[25 * 33 + 26])
  assert_true(q.modules[24 * 33 + 26])
  // Fixed dark module at (25, 8).
  assert_true(q.modules[25 * 33 + 8])
  // Timing patterns at row/col 6.
  assert_true(q.modules[6 * 33 + 8])
  assert_true(!q.modules[6 * 33 + 9])
  // Shapes generated cleanly (dots + finders/alignment).
  let shapes = excerpt_qr_shapes(q, 72.0, ex_ink)
  assert_eq(shapes.length(), 2)
  assert_true(shapes[0].outlines.length() > 100)
  assert_eq(shapes[1].outlines.length(), 12)
}
