// Line numbers, picking, quoting, and noting for code and text files in the viewer (viewer_lines_marks.mbt):
// exact 1-based line ranges, non-selectable line-number gutter, the pick bar (引用 / 批注 / 复制), draft-backed notes
// beside the code on wide stages or behind a foot bar on narrow stages, and persistence across reopen.

///|
let code_marks_sample : Array[String] = [
  "// 列表的行按真实高度排，没量过的先按估计的高度占位",
  "export function moved(rows: number[], at: number, n: number): number[] {",
  "  const out = rows.slice(0, at);",
  "  for (let i = 0; i < n; i++) out.push(-1);",
  "  return out.concat(rows.slice(at));",
  "}",
  "",
  "export const estimate = 66;",
]

///|
test "lines_span_of says the exact 1-based lines of where a pick begins and ends, repeated words included" {
  let count = code_marks_sample.length()
  let at = fn(k : Int) { code_marks_sample[k] }
  // (where line k begins in the row's words: its lines joined by "\n")
  let start = fn(k : Int) {
    let mut n = 0
    for j in 0..<k {
      n += code_marks_sample[j].length() + 1
    }
    n
  }
  // `out` is on lines 3, 4 and 5: picked on line 5 it is line 5, not the first line that has it
  let out5 = start(4) + code_marks_sample[4].find("out").unwrap()
  assert_eq(@sfbase.lines_span_of(count, at, 0, out5, 0, out5 + 3), (5, 5))
  // from inside line 3 to inside line 5
  assert_eq(@sfbase.lines_span_of(count, at, 0, start(2) + 2, 0, start(4) + 8), (3, 5))
  // across the blank line 7, to the end of line 8
  assert_eq(@sfbase.lines_span_of(count, at, 0, start(5), 0, start(7) + code_marks_sample[7].length()), (6, 8))
  // begun on line 2's "\n", ended just past line 4's: lines 3 to 4
  assert_eq(@sfbase.lines_span_of(count, at, 0, start(2) - 1, 0, start(4)), (3, 4))
  // Mark encoding/decoding round-trip and rejection of malformed or foreign marks
  let mark = @sfbase.lines_mark_of((3, 5))
  assert_eq(@sfbase.lines_where_of(mark), Some((3, 5)))
  assert_eq(@sfbase.lines_where_of("x" + mark, from=1), Some((3, 5)))
  assert_eq(@sfbase.lines_where_of("5,3"), None)
  assert_eq(@sfbase.lines_where_of("0,2"), None)
  assert_eq(@sfbase.lines_where_of("md:1,2"), None)
  // Gutter formatting pads right-aligned to the digit count
  assert_eq(@sfbase.lines_gutter_text(0, 2, 2), "\u20071\n\u20072")
  assert_eq(@sfbase.lines_gutter_text(8, 10, 2), "\u20079\n10")
}

///|
fn code_marks_tester(w? : Double = 1280.0, platform? : Int = 0) -> (@ui.Tester, Viewer) {
  let t = preview_tester("code", w~, platform~)
  t.run_for(@ui.move_most_ms)
  (t, viewer.get().unwrap())
}

///|
fn code_draft_quotes() -> Array[Json] {
  @sfbase.writing(preview_src.val.unwrap(), "ws1/st1:s-c1").quotes.get().filter(fn(q) { text(Some(q), "role") == "file" })
}

///|
test "code viewer shows pinned non-selectable line numbers and wide-stage 批注 persists via chat draft" {
  let (t, v) = code_marks_tester()
  let src = preview_src.val.unwrap()
  t.draw()
  // Line-number gutter is drawn for lines 1..8
  assert_true(t.find("\u20071\n\u20072") is Some(_), msg="line-number gutter drawn")
  let (x, y, w, h) = md_words_at(t, "export const estimate = 66;")
  t.drag(x + 1.0, y + h / 2.0, x + w - 1.0, y + h / 2.0)
  t.frame()
  // Picked text contains only code, never the line numbers
  assert_eq(@ui.picked_now().map(fn(p) { p.text }), Some("export const estimate = 66;"))
  assert_true(t.find("引用") is Some(_) && t.find("批注") is Some(_) && t.find("复制") is Some(_), msg="the bar")
  t.tap_text("批注")
  let quotes = code_draft_quotes()
  assert_eq(quotes.length(), 1, msg="in the draft at once")
  assert_eq(text(Some(quotes[0]), "author"), "list.ts 第 8 行")
  assert_eq(text(Some(quotes[0]), "text"), "export const estimate = 66;")
  assert_true(text(Some(quotes[0]), "mark").has_prefix("lines:"), msg="where: \{text(Some(quotes[0]), "mark")}")
  t.type_text("改成常量配置")
  let (kx, ky, kw, kh) = t.get(Button, label="完成").rect
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
  t.draw()
  assert_eq(text(Some(code_draft_quotes()[0]), "comment"), "改成常量配置")
  assert_eq(v.lines_notes().map(fn(x) { (x.lines, x.comment) }), [((8, 8), "改成常量配置")])
  assert_true(t.find("1 条标注") is Some(_), msg="side column head")
  assert_true(t.find("第 8 行") is Some(_) && t.find("改成常量配置") is Some(_), msg="side column card")
  // Highlight mark covers line 8 in row 0
  let marks = v.lines_row_marks(0, code_marks_sample.length(), fn(k) { code_marks_sample[k] })
  assert_eq(marks.length(), 1, msg="line highlighted in runs_marks")
  // Back to chat keeps quote; reopening restores note & highlight
  let file = v.file
  t.tap_text("回到输入框发送")
  t.run_for(@ui.move_most_ms)
  assert_true(viewer.get() is None, msg="closed back to chat")
  assert_eq(code_draft_quotes().length(), 1, msg="still in draft")
  @sfbase.open_preview("ws1/st1", "s-c1", file, beside=false, steps=InChat(Some(1.0), "s-c1"))
  t.frame()
  t.run_for(@ui.move_most_ms)
  t.draw()
  let v = viewer.get().unwrap()
  assert_eq(v.lines_notes().map(fn(x) { (x.lines, x.comment) }), [((8, 8), "改成常量配置")], msg="restored on reopen")
  assert_true(t.find("改成常量配置") is Some(_), msg="card listed again")
  // Removing quote from draft removes note from viewer
  @sfbase.writing_unquote(src, @sfbase.writing(src, "ws1/st1:s-c1"), text(Some(code_draft_quotes()[0]), "id"))
  t.draw()
  assert_eq(v.lines_notes().length(), 0, msg="gone with its quote")
}

///|
test "code viewer 清除标注 removes this file's line notes while keeping other draft quotes" {
  let (t, v) = code_marks_tester()
  let src = preview_src.val.unwrap()
  let draft = @sfbase.writing(src, "ws1/st1:s-c1")
  @sfbase.writing_quote(src, draft, { "author": Json::string("Willow"), "text": Json::string("别的引用"), "role": Json::string("agent") })
  let (x, y, w, h) = md_words_at(t, "const out = rows.slice(0, at);")
  t.drag(x + 1.0, y + h / 2.0, x + w - 1.0, y + h / 2.0)
  t.frame()
  t.tap_text("批注")
  t.type_text("检查边界")
  let (kx, ky, kw, kh) = t.get(Button, label="完成").rect
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
  t.draw()
  assert_eq(code_draft_quotes().length(), 1)
  t.tap_text("清除标注")
  t.draw()
  assert_eq(code_draft_quotes().length(), 0)
  assert_eq(draft.quotes.get().length(), 1, msg="other quote kept")
  assert_eq(v.lines_notes().length(), 0)
}

///|
test "code viewer 引用 puts exact line range into draft immediately and releases selection" {
  let (t, _) = code_marks_tester()
  let (x, y, w, h) = md_words_at(t, "export const estimate = 66;")
  t.drag(x + 1.0, y + h / 2.0, x + w - 1.0, y + h / 2.0)
  t.frame()
  t.tap_text("引用")
  t.run_for(@ui.move_most_ms)
  t.draw()
  let file_quotes = code_draft_quotes()
  assert_eq(file_quotes.length(), 1)
  assert_eq(text(Some(file_quotes[0]), "author"), "list.ts 第 8 行")
  assert_eq(text(Some(file_quotes[0]), "comment"), "")
  assert_eq(@ui.picked_now(), None)
}

///|
test "Markdown 源码 shows line numbers and supports line notes" {
  let (t, v) = md_marks_tester()
  v.set_source(true)
  t.frame()
  t.run_for(@ui.move_most_ms)
  t.draw()
  assert_true(t.find("\u20071\n\u20072") is Some(_), msg="line-number gutter in Markdown source")
  let (x, y, w, h) = md_words_at(t, "- 版本号和更新说明")
  t.drag(x + 1.0, y + h / 2.0, x + w - 1.0, y + h / 2.0)
  t.frame()
  t.tap_text("批注")
  t.type_text("补充版本号规则")
  let (kx, ky, kw, kh) = t.get(Button, label="完成").rect
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
  t.draw()
  assert_eq(v.lines_notes().map(fn(n) { (n.lines, n.comment) }), [((3, 3), "补充版本号规则")])
  assert_eq(text(Some(code_draft_quotes()[0]), "author"), "说明.md 第 3 行")
}

///|
test "code viewer narrow stage shows foot bar and opens notes in a sheet; Markdown 源码 gets line notes too" {
  let (t, v) = code_marks_tester()
  let (x, y, w, h) = md_words_at(t, "export const estimate = 66;")
  t.drag(x + 1.0, y + h / 2.0, x + w - 1.0, y + h / 2.0)
  t.frame()
  t.tap_text("批注")
  t.type_text("太小")
  let (kx, ky, kw, kh) = t.get(Button, label="完成").rect
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
  t.resize(390.0, 844.0)
  t.run_for(@ui.move_most_ms)
  t.draw()
  assert_true(t.find("1 条标注") is Some(_) && t.find("去发送") is Some(_), msg="foot bar on narrow stage")
  assert_true(t.find("回到输入框发送") is None, msg="no side column on narrow stage")
  t.tap_text("1 条标注")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("第 8 行") is Some(_), msg="sheet row")
  t.tap_text("太小")
  t.run_for(@ui.move_most_ms)
  assert_eq(v.lines_marks.writing.get(), v.lines_notes()[0].id, msg="sheet row opened note")
  t.type_text("了")
  let (kx, ky, kw, kh) = t.get(Button, label="完成").rect
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
  assert_eq(v.lines_notes()[0].comment, "太小了")
}

///|
test "code viewer on phone: finger hold picks code words and notes them" {
  let (t, v) = code_marks_tester(w=390.0, platform=2)
  let (x, y, _, h) = md_words_at(t, "export const estimate = 66;")
  t.press_at(x + 4.0, y + h / 2.0)
  t.run_for(@ui.long_press_ms + md_hold_extra_ms)
  t.release(x + 4.0, y + h / 2.0)
  t.frame()
  assert_true(@ui.picked_now().map(fn(p) { p.finger }) == Some(true), msg="finger pick")
  t.tap_text("批注")
  t.type_text("改一下")
  let (kx, ky, kw, kh) = t.get(Button, label="完成").rect
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
  t.draw()
  assert_eq(v.lines_notes().length(), 1)
  assert_true(t.find("1 条标注") is Some(_) && t.find("去发送") is Some(_), msg="foot bar")
}

///|
test "code viewer multi-line selection quotes exact line range and Escape clears selection or finishes note" {
  let (t, v) = code_marks_tester()
  let (x1, y1, _, h1) = md_words_at(t, "const out = rows.slice(0, at);")
  let (x2, y2, w2, h2) = md_words_at(t, "return out.concat(rows.slice(at));")
  t.drag(x1 + 1.0, y1 + h1 / 2.0, x2 + w2 - 1.0, y2 + h2 / 2.0)
  t.frame()
  assert_true(@ui.picked_now() is Some(_), msg="multi-line selection active")
  // (the gutter's numbers are not picked with the lines beside them)
  assert_true(@ui.picked_now().map(fn(p) { p.text.contains("\u2007") || p.text.contains("\n4\n") }) == Some(false))
  t.tap_text("批注")
  assert_eq(text(Some(code_draft_quotes()[0]), "author"), "list.ts 第 3–5 行")
  t.type_text("合并循环")
  // Escape finishes the active note
  t.key(@ui.key_escape)
  t.draw()
  assert_eq(v.lines_marks.writing.get(), "", msg="Escape finished note")
  assert_eq(v.lines_notes().map(fn(n) { (n.lines, n.comment) }), [((3, 5), "合并循环")])
  assert_true(t.find("第 3–5 行") is Some(_), msg="range shown in side card")
  // No new layout audit errors introduced on the code stage with gutter and side notes
  let faults = t.audit().filter(fn(f) { f.contains("viewer_stage_node") || f.contains("viewer_lines_marks") })
  assert_eq(faults, [], msg="no layout faults in code viewer: " + faults.join("; "))
}
