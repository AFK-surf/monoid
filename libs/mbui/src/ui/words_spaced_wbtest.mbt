// Chinese and Japanese words spaced by mbui where the host's shaper spaces none (text.mbt words_spaced_in).

///|
fn spaced_view(text : String) -> Tester {
  Tester::new(
    fn(c) {
      c.column(align=AStart, fn() {
        if text != "" {
          c.text(text, size=16.0) |> ignore
        }
      })
      |> ignore
    },
    w=600.0,
    h=100.0,
  )
}

///|
fn spaced_advances(text : String, style? : Int = 0) -> Array[Double] {
  shape(text, 16.0, 400, style~).adv
}

///|
test "an eighth of an em between Han and a Latin letter or a digit, on the first of the two's advance" {
  let t = spaced_view("在main跑36项CI")
  let before = spaced_advances("在main跑36项CI")
  t.words_spaced_here()
  let after = spaced_advances("在main跑36项CI")
  let added = []
  for k in 0..<after.length() {
    added.push(after[k] - before[k])
  }
  // 在|m, n|跑, 跑|3, 6|项, 项|C: each room after the first of the pair, so each glyph stays where its cluster starts
  assert_eq(added, [2.0, 0.0, 0.0, 0.0, 2.0, 2.0, 0.0, 2.0, 2.0, 0.0, 0.0])
  // the words laid out wider by five eighths of an em, the text as written
  t.draw()
  let (_, _, w, _) = t.rect_of("在main跑36项CI").unwrap()
  let mut sum = 0.0
  for a in before {
    sum = sum + a
  }
  assert_eq(w, sum + 10.0)
}

///|
test "kana spaced as Han; Hangul, spaces and marks not" {
  t_spaced_here()
  assert_eq(spaced_advances("カタカナa"), [16.0, 16.0, 16.0, 18.0, 8.0])
  assert_eq(spaced_advances("한a"), [16.0, 8.0])
  assert_eq(spaced_advances("中 a"), [16.0, 8.0, 8.0])
  assert_eq(spaced_advances("，a"), [16.0, 8.0])
}

///|
fn t_spaced_here() -> Unit {
  let t = spaced_view("")
  t.words_spaced_here()
}

///|
test "a full-width mark a half em closer before another, as chws: never an opening bracket before a closing one" {
  t_spaced_here()
  // 说：「好）。: ：before 「 (a closing mark's empty half), ）before 。; 「 before 好 and 。 at the end left
  assert_eq(spaced_advances("说：「好）。"), [16.0, 8.0, 16.0, 16.0, 8.0, 16.0])
  // two opening brackets: the second's empty first half
  assert_eq(spaced_advances("《「书"), [8.0, 16.0, 16.0])
  // （）: the opening one's ink meets the closing one's
  assert_eq(spaced_advances("（）"), [16.0, 16.0])
}

///|
test "the code face's columns left as a grid" {
  t_spaced_here()
  let mono = spaced_advances("在main跑", style=@hostapi.style_mono)
  for a in mono[1:5] {
    assert_eq(a, 16.0 * 0.6)
  }
  assert_eq(mono[0], 16.0)
  let code = spaced_advances("在main跑", style=@hostapi.face_code << 8)
  assert_eq(code, [16.0, 8.0, 8.0, 8.0, 8.0, 16.0])
}

///|
test "a host that spaces words itself: only its marks set closer; none wanted, left as shaped" {
  let t = spaced_view("")
  // (the fake as a host whose shaper spaces the words but not the marks: Core Text's since macOS 27)
  t.words_spaced_here(by_host=true)
  assert_eq(spaced_advances("在main"), [16.0, 8.0, 8.0, 8.0, 8.0])
  assert_eq(spaced_advances("说：「好）。"), [16.0, 8.0, 16.0, 16.0, 8.0, 16.0])
  t.words_spaced_here(none=true)
  assert_eq(spaced_advances("在main"), [16.0, 8.0, 8.0, 8.0, 8.0])
  assert_eq(spaced_advances("说：「"), [16.0, 16.0, 16.0])
}

///|
test "the words drawn are the text as written, each glyph where its cluster starts" {
  let t = spaced_view("你是Owner")
  t.words_spaced_here()
  t.draw()
  inspect(t.words().map(fn(w) { w.0 }).contains("你是Owner"), content="true")
  let xs = glyph_xs(t)
  // 你 0, 是 16, O 34 (an eighth after 是), then the letters 8 apart
  assert_eq(xs.length(), 7)
  assert_eq(xs[2] - xs[1], 18.0)
  assert_eq(xs[3] - xs[2], 8.0)
}

///|
test "words someone spaced already, by a space, a no-break space or a tab, are given no more room" {
  t_spaced_here()
  assert_eq(spaced_advances("中 a"), [16.0, 8.0, 8.0])
  assert_eq(spaced_advances("中\u{00A0}a"), [16.0, 8.0, 8.0])
  assert_eq(spaced_advances("在 main 跑"), spaced_unspaced("在 main 跑"))
  assert_eq(spaced_advances("在\tmain"), spaced_unspaced("在\tmain"))
}

///|
/// What `text` is shaped as by nobody's spacing (the Tester's run left as it was after).
fn spaced_unspaced(text : String) -> Array[Double] {
  let t = spaced_view("")
  t.words_spaced_here(none=true)
  let a = spaced_advances(text)
  t.words_spaced_here()
  a
}

///|
test "a question mark and an exclamation mark are never set closer" {
  t_spaced_here()
  assert_eq(spaced_advances("？」"), [16.0, 16.0])
  assert_eq(spaced_advances("！」"), [16.0, 16.0])
  assert_eq(spaced_advances("好？！"), [16.0, 16.0, 16.0])
}

///|
test "a clause's mark drawn in the middle of its em (a traditional or a Japanese face) is not set closer; a closing bracket before it is" {
  let t = spaced_view("")
  // (the fake's glyphs drawn a whole 10 points wide from the pen, past the em's middle at 16: as PingFang TC draws
  // 。 and ？, Hiragino ：)
  t.fake.glyph_box = (10.0, 10.0)
  t.words_spaced_here()
  assert_eq(spaced_advances("好。」"), [16.0, 16.0, 16.0])
  assert_eq(spaced_advances("说：「"), [16.0, 16.0, 16.0])
  // ）'s second half empty in every face
  assert_eq(spaced_advances("好）。"), [16.0, 8.0, 16.0])
  assert_eq(spaced_advances("」，"), [8.0, 16.0])
  // a face that draws them in their first half: set closer
  t.fake.glyph_box = (6.0, 10.0)
  t.words_spaced_here()
  assert_eq(spaced_advances("好。」"), [16.0, 8.0, 16.0])
}

///|
/// The advances of a paragraph of `runs` (at 10 points; rich_one_run_wbtest's one_rich) as its runs' loop makes them.
fn spaced_rich(runs : Array[Run]) -> Array[Double] {
  let r = { ..one_rich(plain("")), runs, }
  rich_prep(r, one=false).adv
}

///|
test "where two runs of a paragraph meet, Han beside a Latin letter is spaced as within one run; not across a space or code" {
  let t = spaced_view("")
  t.words_spaced_here(none=true)
  let bare = spaced_rich([plain("在"), bold("main"), plain("跑")])
  let written_spaced = spaced_rich([plain("在 "), bold("main"), plain(" 跑")])
  let in_code = spaced_rich([plain("在"), code("main"), plain("跑")])
  t.words_spaced_here()
  // 在|main and main|跑: an eighth of 10 points after 在 and after n
  let added = []
  let now = spaced_rich([plain("在"), bold("main"), plain("跑")])
  for k in 0..<now.length() {
    added.push(now[k] - bare[k])
  }
  assert_eq(added, [1.25, 0.0, 0.0, 0.0, 1.25, 0.0])
  // a space either side someone wrote: nothing more
  assert_eq(spaced_rich([plain("在 "), bold("main"), plain(" 跑")]), written_spaced)
  // code, its ground's room round it: nothing more
  assert_eq(spaced_rich([plain("在"), code("main"), plain("跑")]), in_code)
  // a host that spaces within a run spaces no more than it is given: where runs meet is mbui's still
  t.words_spaced_here(by_host=true)
  assert_eq(spaced_rich([plain("在"), bold("main"), plain("跑")]), now)
}

///|
test "a paragraph of one run is spaced once, by its shape, whichever way it is made" {
  let t = spaced_view("")
  t.words_spaced_here()
  let r = one_rich(plain("在main跑36项CI，说：「好）。"))
  assert_eq(rich_prep(r).adv, rich_prep(r, one=false).adv)
  let s = shape("在main跑36项CI", 10.0, 400)
  assert_eq(rich_prep(one_rich(plain("在main跑36项CI"))).adv, s.adv)
}
