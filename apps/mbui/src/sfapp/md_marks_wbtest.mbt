// Words of a Markdown file picked in the viewer's reader, and what is done with them: where in the file they are (its
// lines, its heading), the bar over them, the notes on them beside the reader or at its foot: each a quote in the chat's
// draft from the moment it is made, there again when the file is opened again, gone with its quote.

///|
/// The fixture's file (说明.md) as the reader reads it.
let md_marks_text : String = "# 发布前要做的\n\n- 版本号和更新说明\n- 安卓和 mac 的包都签名\n- 截图换成**新的**\n\n> 第二屏的插画再小一点。\n\n`scripts/shots.sh` 会把新截图和旧的比一遍。"

///|
test "words picked are found in the file: their lines, through the marks round them" {
  assert_eq(@sfbase.md_place_of(md_marks_text, [0], 0, 0, "安卓和 mac 的包都签名"), (23, 4, 4))
  let (_, l0, l1) = @sfbase.md_place_of(md_marks_text, [0], 0, 0, "版本号和更新说明\n安卓和 mac 的包都签名")
  assert_eq((l0, l1), (3, 4))
  // (drawn without its `**`: found by fewer of its characters)
  let (_, l0, l1) = @sfbase.md_place_of(md_marks_text, [0], 0, 0, "截图换成新的")
  assert_eq((l0, l1), (5, 5))
  // (none found: the blocks' edges)
  let (at, l0, _) = @sfbase.md_place_of(md_marks_text, [0], 0, 0, "不在文件里")
  assert_eq((at, l0), (0, 1))
  assert_eq(
    @sfbase.md_quote("说明.md", (3, 4), "发布前要做的", "words", "note"),
    ("说明.md 第 3–4 行 · 发布前要做的", "words", "note"),
  )
  // (where a note is, as its quote's mark keeps it, read back; another's or a damaged one says nothing)
  let mark = @sfbase.md_mark_of((2, 3), 23, (4, 4), "发布前要做的")
  assert_eq(@sfbase.md_where_of(mark), Some(((2, 3), 23, (4, 4), "发布前要做的")))
  assert_eq(@sfbase.md_where_of("x" + mark, from=1), Some(((2, 3), 23, (4, 4), "发布前要做的")))
  assert_eq(@sfbase.md_where_of("w:0,0,0,10"), None)
  assert_eq(@sfbase.md_where_of("3,2,0,1,1\n"), None)
}

///|
/// The quotes of the chat's draft said of a file (a Markdown file's notes among them).
fn md_draft_quotes() -> Array[Json] {
  @sfbase.writing(preview_src.val.unwrap(), "ws1/st1:s-c1").quotes.get().filter(fn(q) { text(Some(q), "role") == "file" })
}

///|
/// Where words `s` are drawn: the run that has them.
fn md_words_at(t : @ui.Tester, s : String) -> (Double, Double, Double, Double) raise {
  t.draw()
  match t.run_rects(s) {
    [r, ..] => r
    _ => fail("「\{s}」 not drawn")
  }
}

///|
/// The viewer's Markdown file open in a window `w` wide, its words in.
fn md_marks_tester(w? : Double = 1280.0) -> (@ui.Tester, Viewer) {
  let t = preview_tester("md", w~)
  t.run_for(@ui.move_most_ms)
  (t, viewer.get().unwrap())
}

///|
test "wide: 批注 puts a quote in the draft at once; its note stands beside the reader; closed and opened again it is there; out of the draft it is gone" {
  let (t, v) = md_marks_tester()
  let src = preview_src.val.unwrap()
  let (x, y, w, h) = md_words_at(t, "安卓和 mac 的包都签名")
  t.drag(x + 1.0, y + h / 2.0, x + w - 1.0, y + h / 2.0)
  t.frame()
  assert_true(t.find("引用") is Some(_) && t.find("批注") is Some(_) && t.find("复制") is Some(_), msg="the bar")
  t.tap_text("批注")
  // (in the draft as it is made: the file, its line and heading, the words, where in the file)
  let quotes = md_draft_quotes()
  assert_eq(quotes.length(), 1, msg="in the draft at once")
  assert_eq(text(Some(quotes[0]), "author"), "说明.md 第 4 行 · 发布前要做的")
  assert_eq(text(Some(quotes[0]), "text"), "安卓和 mac 的包都签名")
  assert_true(text(Some(quotes[0]), "mark").has_prefix("md:"), msg="where: \{text(Some(quotes[0]), "mark")}")
  t.type_text("改成三个平台")
  let (kx, ky, kw, kh) = t.get(Button, label="完成").rect
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
  t.draw()
  assert_eq(text(Some(md_draft_quotes()[0]), "comment"), "改成三个平台", msg="what is said of it, the quote's comment")
  assert_eq(v.md_notes().map(fn(x) { (x.lines, x.comment) }), [((4, 4), "改成三个平台")])
  // (the column at the side: its head, the card's place and note, its keys)
  assert_true(t.find("1 条标注") is Some(_), msg="the column's head")
  assert_true(t.find("第 4 行 · 发布前要做的") is Some(_) && t.find("改成三个平台") is Some(_), msg="the card")
  // (the words marked: the passage lent to its paragraph)
  assert_true(v.md_lits(0).length() == 1, msg="marked on the block")
  // (回到输入框发送: back to the chat, the notes in its draft already)
  let file = v.file
  t.tap_text("回到输入框发送")
  t.run_for(@ui.move_most_ms)
  assert_true(viewer.get() is None, msg="closed back to the chat")
  assert_eq(md_draft_quotes().length(), 1, msg="still in the draft")
  // (opened again: its note on the words and beside them, from the draft)
  @sfbase.open_preview("ws1/st1", "s-c1", file, beside=false, steps=InChat(Some(1.0), "s-c1"))
  t.frame()
  t.run_for(@ui.move_most_ms)
  t.draw()
  let v = viewer.get().unwrap()
  assert_eq(v.md_notes().map(fn(x) { (x.lines, x.comment) }), [((4, 4), "改成三个平台")], msg="back on the words")
  assert_true(t.find("改成三个平台") is Some(_), msg="listed again")
  assert_true(v.md_lits(0).length() == 1, msg="marked again")
  // (taken out of the draft in the composer: gone from the words)
  @sfbase.writing_unquote(src, @sfbase.writing(src, "ws1/st1:s-c1"), text(Some(md_draft_quotes()[0]), "id"))
  t.draw()
  assert_eq(v.md_notes().length(), 0, msg="gone with its quote")
  assert_true(v.md_lits(0).length() == 0, msg="its words no longer marked")
}

///|
test "清除标注 takes this file's notes out of the draft, other quotes left in it" {
  let (t, v) = md_marks_tester()
  let src = preview_src.val.unwrap()
  let draft = @sfbase.writing(src, "ws1/st1:s-c1")
  @sfbase.writing_quote(src, draft, { "author": Json::string("Willow"), "text": Json::string("别的引用"), "role": Json::string("agent") })
  let (x, y, w, h) = md_words_at(t, "安卓和 mac 的包都签名")
  t.drag(x + 1.0, y + h / 2.0, x + w - 1.0, y + h / 2.0)
  t.frame()
  t.tap_text("批注")
  t.type_text("改短")
  let (kx, ky, kw, kh) = t.get(Button, label="完成").rect
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
  t.draw()
  assert_eq(md_draft_quotes().length(), 1)
  t.tap_text("清除标注")
  t.draw()
  assert_eq(md_draft_quotes().length(), 0, msg="the file's notes out of the draft")
  assert_eq(draft.quotes.get().length(), 1, msg="the other quote left")
  assert_eq(v.md_notes().length(), 0)
}

///|
test "引用 puts what is picked into the draft at once, with its lines" {
  let (t, _) = md_marks_tester()
  let (x, y, w, h) = md_words_at(t, "版本号和更新说明")
  t.drag(x + 1.0, y + h / 2.0, x + w - 1.0, y + h / 2.0)
  t.frame()
  t.tap_text("引用")
  t.run_for(@ui.move_most_ms)
  t.draw()
  let quotes = @sfbase.writing(preview_src.val.unwrap(), "ws1/st1:s-c1").quotes.get()
  assert_eq(quotes.length(), 1)
  assert_eq(text(Some(quotes[0]), "author"), "说明.md 第 3 行 · 发布前要做的")
  assert_eq(text(Some(quotes[0]), "comment"), "")
  assert_eq(@ui.picked_now(), None, msg="let go")
}

///|
test "narrow: no column; a count at the foot opens the notes in a sheet, a row opens its note to be written on" {
  let (t, v) = md_marks_tester()
  let (x, y, w, h) = md_words_at(t, "安卓和 mac 的包都签名")
  t.drag(x + 1.0, y + h / 2.0, x + w - 1.0, y + h / 2.0)
  t.frame()
  t.tap_text("批注")
  t.type_text("这里")
  let (kx, ky, kw, kh) = t.get(Button, label="完成").rect
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
  // (the window narrowed to a phone's width: the reader's whole width for its words, the notes at its foot)
  t.resize(390.0, 844.0)
  t.run_for(@ui.move_most_ms)
  t.draw()
  assert_true(t.find("1 条标注") is Some(_) && t.find("去发送") is Some(_), msg="the foot")
  assert_true(t.find("回到输入框发送") is None, msg="no column")
  t.tap_text("1 条标注")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("第 4 行 · 发布前要做的") is Some(_), msg="the sheet's row")
  t.tap_text("这里")
  t.run_for(@ui.move_most_ms)
  assert_eq(v.md_marks.writing.get(), v.md_notes()[0].id, msg="the row opened its note")
  t.type_text("，再短")
  assert_eq(v.md_marks.note.text(), "这里，再短", msg="written on as the sheet went")
  let (kx, ky, kw, kh) = t.get(Button, label="完成").rect
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
  assert_eq(v.md_notes()[0].comment, "这里，再短")
}

///|
/// Held a little past a long press.
let md_hold_extra_ms : Double = 20.0

///|
test "a phone: a finger held on the words picks them (not the reader's bars), with the page's bar to note them" {
  let t = preview_tester("md", platform=2)
  t.run_for(@ui.move_most_ms)
  let v = viewer.get().unwrap()
  let (x, y, _, h) = md_words_at(t, "安卓和 mac 的包都签名")
  t.press_at(x + 4.0, y + h / 2.0)
  t.run_for(@ui.long_press_ms + md_hold_extra_ms)
  t.release(x + 4.0, y + h / 2.0)
  t.frame()
  assert_true(@ui.picked_now().map(fn(p) { p.finger }) == Some(true), msg="a finger's pick")
  t.tap_text("批注")
  t.type_text("这里")
  let (kx, ky, kw, kh) = t.get(Button, label="完成").rect
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
  t.draw()
  assert_eq(v.md_notes().length(), 1)
  assert_true(t.find("1 条标注") is Some(_) && t.find("去发送") is Some(_), msg="the foot")
}

///|
test "a phone: a tap on the words finishes the note being written; the reader's bars, shown, keep the notes' foot away" {
  let t = preview_tester("md", platform=2)
  t.run_for(@ui.move_most_ms)
  let v = viewer.get().unwrap()
  let (x, y, _, h) = md_words_at(t, "安卓和 mac 的包都签名")
  t.press_at(x + 4.0, y + h / 2.0)
  t.run_for(@ui.long_press_ms + md_hold_extra_ms)
  t.release(x + 4.0, y + h / 2.0)
  t.frame()
  t.tap_text("批注")
  t.type_text("这里")
  // (a tap on the text, under the words: the note finished, not the reader's bars brought)
  let (sx, sy, _, _) = md_words_at(t, "会把新截图和旧的比一遍")
  t.tap(sx + 4.0, sy + 120.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(v.md_marks.writing.get(), "", msg="the note finished")
  assert_eq(v.md_notes()[0].comment, "这里")
  assert_true(t.find("1 条标注") is Some(_), msg="the foot, the reader's bars not brought")
  // (a tap again: the reader's bars, the notes' foot away for them, never under them)
  t.tap(sx + 4.0, sy + 120.0)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("1 条标注") is None, msg="the foot away while the reader's bars show")
  t.tap(sx + 4.0, sy + 120.0)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("1 条标注") is Some(_), msg="the foot back as they go")
}
