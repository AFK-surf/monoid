// A phone's reader's track (reader_node's on 小屏): a tap or a drag along it goes there as it is let go, by the text's
// length, whatever its blocks are.

///|
/// A reading of `book` (as `key`) made as nodes in a phone's window `w` by `h`, its bars shown, at rest.
fn track_tester(key : String, book : Book, w? : Double = 390.0, h? : Double = 844.0) -> (@ui.Tester, Reading) {
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w~, h~, platform=2)
  // (its book here already: nothing read; after the run begins, which lets go of every reading)
  let r = reading_for(key)
  r.asked = true
  r.book.set(Some(book))
  r.chrome.set(true)
  let file = blob_file(@utf8.encode(book.text), "book.txt", book.length.to_double(), save=fn() {  })
  @ui.set_view_app(fn(root) {
    reader_node(root, key, file, markdown=false, back_label=fn() { "返回" }, on_back=fn() {  }) |> ignore
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  (t, r)
}

///|
/// A book of `chunks`, its text all of them.
fn track_book(id : Int, title : String, chunks : Array[String]) -> Book {
  let starts = []
  let mut at = 0
  for c in chunks {
    starts.push(at)
    at += c.length()
  }
  {
    title,
    id,
    text: chunks.join(""),
    chunks,
    starts,
    parts: [],
    length: at,
    chapters: [],
    heads: Map([]),
    encoding: "UTF-8",
    truncated: false,
    markdown: false,
  }
}

///|
test "the reader's track jumps on a tap with no frame drawn while pressed" {
  let (t, r) = track_tester("track-tap", track_book(1, "Book", ["a", "b", "c", "d"]))
  let (x, y, w, h) = t.get(Slider).rect
  t.tap(x + w * 0.75, y + h / 2.0)
  assert_eq(r.jump.get().map(fn(j) { j.0 }), Some(3), msg="the tap reaches the selected part")
  // Start a drag in one frame, then move and release before the next.
  t.touch(0, x + w * 0.2, y + h / 2.0)
  t.draw()
  t.touch(1, x + w * 0.9, y + h / 2.0)
  t.touch(2, x + w * 0.9, y + h / 2.0)
  t.draw()
  assert_eq(r.jump.get().map(fn(j) { j.0 }), Some(3), msg="the drag reaches where it ended")
  reader_let_go("track-tap")
}

///|
test "a short book's track reaches the middle of its text" {
  let words = "0123456789".repeat(10)
  let (t, r) = track_tester("track-short", track_book(2, "Short book", [words]))
  let (x, y, w, h) = t.get(Slider).rect
  t.tap(x + w / 2.0, y + h / 2.0)
  assert_eq(r.jump.get(), Some((0, 50, true)), msg="the middle of the track reaches the middle of the text")
  reader_let_go("track-short")
}

///|
test "tapping the middle of a short book's track scrolls its text" {
  let words = "小说正文".repeat(225)
  let (t, r) = track_tester("track-short-scroll", track_book(4, "Short book", [words]), h=350.0)
  let (x, y, w, h) = t.get(Slider).rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  guard r.list.sight_now() is Some(s) else { fail("the list says nothing in sight") }
  assert_eq(s.first, 0)
  assert_true(s.into > 0.0, msg="the text moved down from its beginning: \{Repr(s)}")
  reader_let_go("track-short-scroll")
}

///|
test "a book's track follows text position when its blocks have different lengths" {
  let book = track_book(3, "Uneven book", ["a".repeat(90), "b".repeat(10)])
  assert_true((reader_fraction(book, (0, 0.5)) - 0.45).abs() < 0.000001, msg="halfway through the first 90 characters is 45% of the book")
  let (t, r) = track_tester("track-uneven", book)
  let (x, y, w, h) = t.get(Slider).rect
  t.tap(x + 11.0 + (w - 22.0) * 0.95, y + h / 2.0)
  assert_eq(r.jump.get().map(fn(j) { (j.0, j.1) }), Some((1, 5)), msg="95% reaches the middle of the last 10 characters")
  reader_let_go("track-uneven")
}

///|
test "on 小屏 a panel open keeps no room of the text's: the column as wide under its sheet as without it" {
  let words = "小说正文".repeat(60)
  let (t, r) = track_tester("track-panel", track_book(5, "Book", [words]))
  let line = fn() {
    match t.words().filter(fn(w) { w.0.contains("小说正文") }) {
      [w, ..] => w.3
      _ => 0.0
    }
  }
  let was = line()
  @ui.view_tree().unwrap().event(t.time(), fn() { reader_open_panel(r, Contents) })
  t.run_for(@ui.move_most_ms)
  assert_true(was > 200.0 && line() == was, msg="as wide: \{was}, then \{line()}")
  reader_let_go("track-panel")
}
