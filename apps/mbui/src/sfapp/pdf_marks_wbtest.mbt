// Words of a PDF picked over the picture the host draws of it, and what is done with them: by what a person does (a
// drag, a held finger, the bar's keys) and what the chat's draft comes to hold.

///|
/// A PDF of three pages of 600 × 800, each a line of words at (100, 700) in a font 10 wide a letter at 20.
fn pdf_marks_file() -> Bytes {
  let out = StringBuilder()
  out.write_string("%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
  out.write_string("2 0 obj\n<< /Type /Pages /MediaBox [0 0 600 800] /Count 3 /Kids [10 0 R 12 0 R 14 0 R] >>\nendobj\n")
  out.write_string("3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 32 /LastChar 122 /Widths [")
  for _ in 32..=122 {
    out.write_string("500 ")
  }
  out.write_string("] /Encoding /WinAnsiEncoding >>\nendobj\n")
  for k, words in ["first page words", "second page words", "third page words"] {
    let c = "BT /F1 20 Tf 100 700 Td (\{words}) Tj ET"
    out.write_string("\{10 + 2 * k} 0 obj\n<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 3 0 R >> >> /Contents \{11 + 2 * k} 0 R >>\nendobj\n")
    out.write_string("\{11 + 2 * k} 0 obj\n<< /Length \{c.length()} >>\nstream\n\{c}\nendstream\nendobj\n")
  }
  out.write_string("trailer\n<< /Root 1 0 R >>\n%%EOF\n")
  let s = out.to_string()
  Bytes::makei(s.length(), fn(i) { s.code_unit_at(i).to_int().to_byte() })
}

///|
/// The preview of a PDF whose words are the file above's, and where its first page is drawn.
fn pdf_marks_tester(platform? : Int = 0, w? : Double = 390.0) -> (@ui.Tester, Viewer, Double, Double, Double, Double) {
  let t = preview_tester("pdf", platform~, w~)
  let v = viewer.get().unwrap()
  v.pdf_marks.doc = @pdftext.Doc::open(pdf_marks_file())
  v.pdf_marks.read = true
  t.draw()
  let img = t.drawn_images()[0]
  (t, v, img[0], img[1], img[2], img[3])
}

///|
test "a mouse's drag picks words; the bar copies them" {
  let (t, v, x, y, w, h) = pdf_marks_tester()
  let at = fn(u : Double, v : Double) { (x + u * w, y + v * h) }
  // ("first page": from the first letter's left to the tenth's right, on the line 100 down of 800)
  let (x0, y0) = at(100.5 / 600.0, 100.0 / 800.0)
  let (x1, y1) = at(199.5 / 600.0, 100.0 / 800.0)
  t.drag(x0, y0, x1, y1)
  assert_eq(v.pdf_marks.picked.get(), Some(Words(0, 0, 0, 10)))
  assert_eq(@sfbase.pdf_words_of(v.pdf_marks.doc, Words(0, 0, 0, 10)), "first page")
  assert_true(t.find("引用") is Some(_) && t.find("批注") is Some(_) && t.find("复制") is Some(_), msg="the bar")
  t.tap_text("复制")
  assert_true(v.pdf_marks.picked.get() is None, msg="copied, let go")
  // (picked again: the copy key copies it, Escape lets it go)
  t.drag(x0, y0, x1, y1)
  t.key(@ui.key_code_copy)
  assert_eq(t.clipboard(), "first page")
  t.key(@ui.key_escape)
  assert_true(v.pdf_marks.picked.get() is None, msg="Escape let go")
}

///|
test "a drag over onto the next page picks across them" {
  let (t, v, x, y, w, h) = pdf_marks_tester()
  let (x0, y0) = (x + 250.5 / 600.0 * w, y + 100.0 / 800.0 * h)
  // (the second page's line: a page and the gap between them down)
  let (x1, y1) = (x + 199.5 / 600.0 * w, y + h + 12.0 + 100.0 / 800.0 * h)
  let (_, wh) = (0.0, 844.0)
  guard y1 < wh else { fail("the second page's line is off the window") }
  t.drag(x0, y0, x1, y1)
  match v.pdf_marks.picked.get() {
    Some(Words(0, _, 1, 10)) => ()
    other => fail("picked \{Repr(other)}")
  }
}

///|
test "a drag off the words frames an area of the page" {
  let (t, v, x, y, w, h) = pdf_marks_tester()
  t.drag(x + 0.2 * w, y + 0.4 * h, x + 0.6 * w, y + 0.6 * h)
  match v.pdf_marks.picked.get() {
    Some(Area(0, x0, y0, x1, y1)) =>
      assert_true((x0 - 0.2).abs() < 0.01 && (y0 - 0.4).abs() < 0.01 && (x1 - 0.6).abs() < 0.01 && (y1 - 0.6).abs() < 0.01)
    other => fail("picked \{Repr(other)}")
  }
  let q = @sfbase.pdf_quote("设计说明.pdf", Area(0, 0.2, 0.4, 0.6, 0.6), "", "")
  assert_eq(q.0, "设计说明.pdf 第 1 页")
  assert_eq(q.1, "页面区域：距左 20%，距上 40%，宽 40%，高 20%")
}

///|
test "a note kept on the page goes into the draft with its words, its file and its page" {
  let (t, v, x, y, w, h) = pdf_marks_tester()
  let src = preview_src.val.unwrap()
  t.drag(x + 100.5 / 600.0 * w, y + 100.0 / 800.0 * h, x + 199.5 / 600.0 * w, y + 100.0 / 800.0 * h)
  t.tap_text("批注")
  assert_eq(v.pdf_marks.marks.length(), 1)
  t.type_text("这里改一下")
  let (kx, ky, kw, kh) = t.get(Button, label="完成").rect
  // (its card at the stage's foot, as a picture's note is: never over the words round what it is said of)
  let (_, wh) = t.size()
  assert_true(ky > y + 100.0 / 800.0 * h + 40.0 && ky + kh <= wh, msg="the note's card at the foot: \{ky} in \{wh}")
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
  assert_eq(v.pdf_marks.marks[0].comment, "这里改一下")
  assert_true(t.find("1 条标注") is Some(_) && t.find("发送") is Some(_), msg="what lists and sends the notes")
  t.tap_text("发送")
  assert_eq(v.pdf_marks.marks.length(), 0, msg="sent")
  t.run_for(@ui.move_most_ms)
  t.draw()
  let quotes = @sfbase.writing(src, "ws1/st1:s-c1").quotes.get()
  assert_eq(quotes.length(), 1)
  assert_eq(text(Some(quotes[0]), "author"), "设计说明.pdf 第 1 页")
  assert_eq(text(Some(quotes[0]), "text"), "first page")
  assert_eq(text(Some(quotes[0]), "comment"), "这里改一下")
  assert_eq(text(Some(quotes[0]), "role"), "pdf")
}

///|
/// Long enough for a finger's fling over the pages to come to rest.
let pdf_fling_over_ms : Double = 3000.0

///|
test "a finger that moves scrolls the pages; one held picks the word under it" {
  let (t, v, x, y, w, h) = pdf_marks_tester(platform=2)
  let (px, py) = (x + 130.0 / 600.0 * w, y + 100.0 / 800.0 * h)
  t.drag(px, py + 120.0, px, py - 40.0)
  assert_true(v.pdf_marks.picked.get() is None, msg="a finger that moved picked nothing")
  // (its fling over: the second page's line, where it is now)
  t.run_for(pdf_fling_over_ms)
  let second = t.drawn_images()[1]
  assert_true(second[1] < y + h, msg="it scrolled")
  let held_y = second[1] + 100.0 / 800.0 * second[3]
  t.touch(0, px, held_y)
  t.run_for(@ui.long_press_ms + tap_hold_extra_ms)
  t.touch(2, px, held_y)
  t.draw()
  match v.pdf_marks.picked.get() {
    Some(what) => assert_eq(@sfbase.pdf_words_of(v.pdf_marks.doc, what), "second")
    None => fail("held at \{Repr((px, held_y))} on a page at \{Repr(t.drawn_images().map(fn(i) { (i[0], i[1], i[2], i[3]) }))}: nothing picked")
  }
}

///|
/// A note made on the first page's words, from a drag to 完成 (its words written first where `said`).
fn pdf_note_made(t : @ui.Tester, x : Double, y : Double, w : Double, h : Double, said? : String = "") -> Unit raise {
  t.drag(x + 100.5 / 600.0 * w, y + 100.0 / 800.0 * h, x + 199.5 / 600.0 * w, y + 100.0 / 800.0 * h)
  t.tap_text("批注")
  if said != "" {
    t.type_text(said)
  }
  let (kx, ky, kw, kh) = t.get(Button, label="完成").rect
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
}

///|
test "wide: the notes stand at the pages' side; a card opens its note, its bin takes it off" {
  let (t, v, x, y, w, h) = pdf_marks_tester(w=1280.0)
  pdf_note_made(t, x, y, w, h, said="改短一点")
  t.draw()
  assert_true(t.find("1 条标注") is Some(_), msg="the column's head")
  assert_true(t.find("first page") is Some(_) && t.find("改短一点") is Some(_), msg="the card: its words and its note")
  // (the pages narrowed for the column, clear of it)
  let page = t.drawn_images()[0]
  assert_true(page[0] + page[2] <= 1280.0 - @sfbase.doc_notes_side_w, msg="the page clear of the column: \{Repr(page)}")
  // (no bar at the foot: the column has the keys)
  assert_true(t.find("发送 1 条标注") is Some(_))
  t.tap_text("改短一点")
  assert_eq(v.pdf_marks.writing.get(), v.pdf_marks.marks[0].id, msg="the card opened its note")
  assert_eq(v.pdf_marks.note.text(), "改短一点")
  let (kx, ky, kw, kh) = t.get(Button, label="完成").rect
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
  let bins = t.all(Button, label="删除批注")
  assert_true(bins.length() >= 1, msg="the card's bin")
  let (bx, by, bw, bh) = bins[0].rect
  t.tap(bx + bw / 2.0, by + bh / 2.0)
  assert_eq(v.pdf_marks.marks.length(), 0, msg="taken off")
  t.draw()
  assert_true(t.find("1 条标注") is None, msg="the column gone with the last note")
}

///|
test "narrow: a count at the foot opens the notes in a sheet; a row opens its note on the page" {
  let (t, v, x, y, w, h) = pdf_marks_tester(platform=2)
  // (a finger: held on the words, slid along them)
  let (px, py) = (x + 100.5 / 600.0 * w, y + 100.0 / 800.0 * h)
  t.touch(0, px, py)
  t.run_for(@ui.long_press_ms + tap_hold_extra_ms)
  t.hold_move(x + 150.5 / 600.0 * w, py)
  t.hold_move(x + 199.5 / 600.0 * w, py)
  t.touch(2, x + 199.5 / 600.0 * w, py)
  t.draw()
  assert_eq(v.pdf_marks.picked.get(), Some(Words(0, 0, 0, 10)), msg="held and slid: the words")
  t.tap_text("批注")
  t.type_text("这里")
  let (kx, ky, kw, kh) = t.get(Button, label="完成").rect
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
  t.draw()
  // (the foot: the count and 发送, no column at this width)
  assert_true(t.find("1 条标注") is Some(_) && t.find("发送") is Some(_), msg="the foot's count and 发送")
  t.tap_text("1 条标注")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("第 1 页") is Some(_) && t.find("这里") is Some(_), msg="the sheet's row")
  t.tap_text("这里")
  t.run_for(@ui.move_most_ms)
  assert_eq(v.pdf_marks.writing.get(), v.pdf_marks.marks[0].id, msg="the row opened its note")
  // (the sheet gone, its note's field still takes what is typed)
  t.type_text("，短些")
  assert_eq(v.pdf_marks.note.text(), "这里，短些", msg="written on as the sheet went")
}

///|
test "a finger held off the words frames an area as it slides" {
  let (t, v, x, y, w, h) = pdf_marks_tester(platform=2)
  let (px, py) = (x + 0.3 * w, y + 0.5 * h)
  t.touch(0, px, py)
  t.run_for(@ui.long_press_ms + tap_hold_extra_ms)
  t.hold_move(x + 0.5 * w, y + 0.55 * h)
  t.hold_move(x + 0.7 * w, y + 0.6 * h)
  t.touch(2, x + 0.7 * w, y + 0.6 * h)
  t.draw()
  match v.pdf_marks.picked.get() {
    Some(Area(0, x0, y0, x1, y1)) =>
      assert_true((x0 - 0.3).abs() < 0.02 && (y0 - 0.5).abs() < 0.02 && (x1 - 0.7).abs() < 0.02 && (y1 - 0.6).abs() < 0.02)
    other => fail("picked \{Repr(other)}")
  }
  assert_true(t.find("批注") is Some(_), msg="its bar")
}

///|
/// A little longer than a long press, for a hold to be taken.
let tap_hold_extra_ms : Double = 20.0
