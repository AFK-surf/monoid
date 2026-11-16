// A chapter gone to (the contents' row, 上一章 and 下一章, ← and →) is the chapter read from then: its heading at the
// top, the bar's chapter, the contents' mark and the next 下一章 its own, never the one before it.

///|
/// A novel of five chapters, each heading in a block of the text after the one before's end (as a phone's reader
/// cuts it), as the core reads it (`reader.book`).
fn chapters_book() -> Book {
  let titles = ["第一章 雨后的车站", "第二章 旧仓库", "第三章 灯塔的钥匙", "第四章 回程", "尾声"]
  let lines = [
    "雨停的时候，站台上只剩下一盏灯还亮着，他把伞收好，靠在柱子旁边数着远处驶来的车厢。", "她说那封信是从北边寄来的，邮戳已经模糊，只能看出一个“七”字，像是某个月份，也像是某条街的门牌。",
    "仓库的门比想象中轻，推开时没有声音，只有一股潮湿的木头味道慢慢涌出来。", "风从海面吹过来，把灯塔下的旗子拉得笔直，守塔的老人说今晚不会再有船经过了。",
  ]
  let out = StringBuilder()
  let chapters = []
  let heads = []
  for i, title in titles {
    let at = out.to_string().length()
    chapters.push({ title, offset: at })
    heads.push(at)
    out.write_string(title)
    out.write_char('\n')
    for k in 0..<14 {
      out.write_string("\u{3000}\u{3000}")
      out.write_string(lines[(i + k) % lines.length()])
      out.write_string(lines[(i * 3 + k) % lines.length()])
      out.write_char('\n')
    }
    out.write_char('\n')
  }
  book_of("长篇小说", { id: 7, text: out.to_string(), wrapped: 0, chapters, heads, md: [] }, "UTF-8", false, false)
}

///|
/// The book read as `key` in a window `w` by `h` (a phone's at 390), its bars shown, at rest.
fn chapters_tester(key : String, w : Double, h : Double) -> (@ui.Tester, Reading, Book) {
  let book = chapters_book()
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w~, h~, platform=if w < 600.0 { 2 } else { 0 })
  let r = reading_for(key)
  r.asked = true
  r.book.set(Some(book))
  r.chrome.set(true)
  let file = blob_file(@utf8.encode(book.text), "长篇小说.txt", book.length.to_double(), save=fn() {  })
  @ui.set_view_app(fn(root) {
    reader_node(root, key, file, markdown=false, back_label=fn() { "返回" }, on_back=fn() {  }) |> ignore
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  (t, r, book)
}

///|
/// The chapter read, and the contents' row marked so.
fn chapter_now(r : Reading, book : Book) -> Int {
  reader_chapter(book, r.place.get())
}

///|
test "on 小屏 a chapter gone to from the contents is the one read, and 下一章 goes on from it to the last" {
  let next = t("web-pages.drive.reader.nextChapter")
  let prev = t("web-pages.drive.reader.prevChapter")
  let search = t("web-pages.drive.reader.findPlaceholder")
  let (t, r, book) = chapters_tester("chapters-small", 390.0, 844.0)
  assert_true(book.chapters.length() == 5 && book.chapters[3].2 > 0, msg="the fourth chapter's heading inside a block")
  @ui.view_tree().unwrap().event(t.time(), fn() { reader_open_panel(r, Contents) })
  t.run_for(2.0 * @ui.move_most_ms)
  assert_true(t.words().any(fn(w) { w.0 == search }), msg="its sheet up")
  t.click(Button, label="第四章 回程")
  t.run_for(2.0 * @ui.move_most_ms)
  assert_eq(chapter_now(r, book), 3, msg="the fourth chapter read")
  assert_true(r.panel.get() == NoPanel, msg="the contents closed as it is gone to")
  assert_true(!t.words().any(fn(w) { w.0 == search }), msg="its sheet gone: \{Repr(t.words().map(fn(w) { w.0 }))}")
  assert_true(t.words().any(fn(w) { w.0 == "第四章 回程" }), msg="the bar says the fourth chapter")
  // (its heading in sight under the top bar, which still shows: not under it, nor far below it)
  let under = narrow_bar_off + narrow_found_down
  let heading = t.text_runs().filter(fn(l) { l.text == "第四章 回程" && l.top < 400.0 })
  assert_true(
    heading.length() == 1 && heading[0].top >= under - 1.0 && heading[0].top < under + 24.0,
    msg="its heading under the bar: \{Repr(heading.map(fn(l) { l.top }))}",
  )
  t.click(Button, label=next)
  t.run_for(@ui.move_most_ms)
  assert_eq(chapter_now(r, book), 4, msg="下一章: the last")
  t.click(Button, label=prev)
  t.run_for(@ui.move_most_ms)
  assert_eq(chapter_now(r, book), 3, msg="上一章: the fourth again")
  // from the first, 下一章 one press at a time to the last
  t.click(Button, label=prev)
  t.run_for(@ui.move_most_ms)
  t.click(Button, label=prev)
  t.run_for(@ui.move_most_ms)
  t.click(Button, label=prev)
  t.run_for(@ui.move_most_ms)
  assert_eq(chapter_now(r, book), 0, msg="back to the first")
  for to in 1..<5 {
    t.click(Button, label=next)
    t.run_for(@ui.move_most_ms)
    assert_eq(chapter_now(r, book), to, msg="下一章 to chapter \{to + 1}")
  }
  reader_let_go("chapters-small")
}

///|
test "on 大屏 a chapter gone to from the contents beside the text is the one marked in them" {
  let (t, r, book) = chapters_tester("chapters-large", 1280.0, 800.0)
  @ui.view_tree().unwrap().event(t.time(), fn() { reader_open_panel(r, Contents) })
  t.run_for(@ui.move_most_ms)
  for i in [3, 1, 4, 2] {
    t.click(Button, label=book.chapters[i].0)
    t.run_for(@ui.move_most_ms)
    assert_eq(chapter_now(r, book), i, msg="\{book.chapters[i].0} read")
    assert_true(t.words().any(fn(w) { w.0 == book.chapters[i].0 }), msg="\{book.chapters[i].0} shown")
  }
  reader_let_go("chapters-large")
}

///|
test "a place found is brought a little under the top, the chapter it is in read" {
  let (t, r, book) = chapters_tester("chapters-found", 390.0, 844.0)
  let (_, k, o) = book.chapters[3]
  @ui.view_tree().unwrap().event(t.time(), fn() { reader_jump(r, k, o + 40, lead=true) })
  t.run_for(@ui.move_most_ms)
  guard r.list.sight_now() is Some(s) else { fail("nothing in sight") }
  assert_eq(s.first, k)
  assert_true(s.into > 0.0, msg="a little before it showing too: \{Repr(s)}")
  reader_let_go("chapters-found")
}

///|
test "a desktop's window made narrow to 小屏 and wide again keeps its reader's bars as they were made" {
  let find = t("web-pages.drive.reader.find")
  let next = t("web-pages.drive.reader.nextChapter")
  let (t, _, _) = chapters_tester("chapters-resized", 1280.0, 800.0)
  let desk = t.get(Button, label=find).id
  t.resize(390.0, 844.0)
  t.run_for(@ui.move_most_ms)
  let phone = t.get(Button, label=next).id
  t.resize(1280.0, 800.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Button, label=find).id, desk, msg="the desktop's bar the one made first")
  t.resize(390.0, 844.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Button, label=next).id, phone, msg="the phone's bars the ones made first")
  reader_let_go("chapters-resized")
}
