// What shape_widths keeps of each face's marks of ambiguous width (marks_narrow): the clusters come out as the words
// cut and looked through every time made them.

///|
/// shape_widths as it was before marks_narrow: every word with a piece of narrow marks looked through, its marks
/// measured, cut and shaped again where the face drew one a whole em.
fn shape_widths_whole(text : String, size : Double, weight : Int, style : Int, out : FixedArray[Double]) -> Int {
  let k = h_shape(text, size, weight, style, out)
  let runs = @text.width_runs(text)
  guard runs.length() > 1 || runs[0].2 else { return k }
  let mut wide = false
  let mut r = 0
  for j in 0..<k {
    let st = out[j * 4].to_int()
    while r < runs.length() - 1 && st >= runs[r].1 {
      r = r + 1
    }
    if runs[r].2 && @text.width_mark(text, st) && out[j * 4 + 2] >= size * 0.95 {
      wide = true
      break
    }
  }
  guard wide else { return k }
  let cap = out.length() / 4
  let part = FixedArray::make(out.length(), 0.0)
  let mut k = 0
  for run in runs {
    let (a, b, narrow) = run
    let style = if narrow { style | @hostapi.style_proportional } else { style }
    let m = h_shape(text.unsafe_substring(start=a, end=b), size, weight, style, part)
    for j in 0..<m {
      if k >= cap {
        break
      }
      out[k * 4] = part[j * 4] + a.to_double()
      out[k * 4 + 1] = part[j * 4 + 1]
      out[k * 4 + 2] = part[j * 4 + 2]
      out[k * 4 + 3] = part[j * 4 + 3]
      k = k + 1
    }
  }
  k
}

///|
/// The clusters of `text` as shape_widths gives them now, beside those it gave before marks_narrow.
fn marks_both(text : String, size : Double, weight : Int, style : Int) -> (Array[Double], Array[Double]) {
  let a = FixedArray::make(4 * 256, 0.0)
  let b = FixedArray::make(4 * 256, 0.0)
  let ka = shape_widths(text, size, weight, style, a)
  let kb = shape_widths_whole(text, size, weight, style, b)
  (
    Array::makei(ka * 4, fn(i) { a[i] }),
    Array::makei(kb * 4, fn(i) { b[i] }),
  )
}

///|
// (the words looked at: Latin's quotes and ellipsis among letters, beside Han, alone, with marks of each kind, with
// none, a joined emoji, an accent, CRLF)
let marks_words : Array[String] = [
  "it’s", "don’t stop…", "我喜欢“Hello”这个词", "你“A” ok", "a·b • c ‧ d", "‘quoted’ and “double”", "plain ascii",
  "纯中文没有标记", "…", "’", "é’s café", "👨‍👩‍👧 it’s", "line\r\nit’s", "混排 it’s 和 “引号”",
]

///|
test "a face that draws its marks narrow: what is kept of them gives the clusters looking through gave, and goes with the shapes" {
  let _t = Tester::new(fn(_c) {  }, w=200.0, h=100.0)
  assert_true(marks_narrow.is_empty())
  // cold, then each again with all of them known
  for round in 0..<2 {
    for s in marks_words {
      let (now, whole) = marks_both(s, 15.0, 400, 0)
      assert_eq(now, whole, msg="round \{round}: \{s}")
    }
  }
  // what was seen narrow among Latin letters is kept for the face (’ … · • ‧ ‘ “ ”), nothing for another weight
  let face = marks_face(400, 0)
  let known = marks_narrow.get(face).unwrap_or(0)
  for c in [0x2019, 0x2026, 0xB7, 0x2022, 0x2027, 0x2018, 0x201C, 0x201D] {
    assert_true((known & width_mark_bit(c)) != 0, msg="mark \{c}")
  }
  assert_eq(marks_narrow.get(marks_face(700, 0)), None)
  // the same at another size: the face's marks are narrow at any
  for s in marks_words {
    let (now, whole) = marks_both(s, 31.0, 400, 0)
    assert_eq(now, whole, msg="size 31: \{s}")
  }
  // forgotten with the shapes (a Tester's run, the host's faces changed)
  clear_shapes()
  assert_true(marks_narrow.is_empty())
}

///|
test "a face that draws its marks a whole em (a CJK face): nothing is kept narrow, every word cut and shaped again as before" {
  let t = Tester::new(fn(_c) {  }, w=200.0, h=100.0)
  t.cjk_face_marks()
  for round in 0..<2 {
    for s in marks_words {
      let (now, whole) = marks_both(s, 15.0, 400, 0)
      assert_eq(now, whole, msg="round \{round}: \{s}")
    }
  }
  // (its quotes, ellipsis and bullet a whole em: none kept narrow; a middle dot it draws narrow may be)
  let known = marks_narrow.get(marks_face(400, 0)).unwrap_or(0)
  for c in [0x2018, 0x2019, 0x201C, 0x201D, 0x2026, 0x2022, 0x2027] {
    assert_eq(known & width_mark_bit(c), 0, msg="mark \{c}")
  }
  // "it’s" in it: its quote cut out and shaped narrow (style_proportional), as before
  let (now, _) = marks_both("it’s", 15.0, 400, 0)
  assert_true(now[2 * 4 + 2] < 15.0 * 0.95)
}

///|
test "a mark known narrow in one face is not taken for another: the same mark a whole em in it is still cut" {
  let t = Tester::new(fn(_c) {  }, w=200.0, h=100.0)
  // the face at 400 seen narrow
  let (n0, w0) = marks_both("it’s", 15.0, 400, 0)
  assert_eq(n0, w0)
  assert_true((marks_narrow.get(marks_face(400, 0)).unwrap_or(0) & width_mark_bit(0x2019)) != 0)
  // the host's faces now draw it a whole em (faces given: the shapes forgotten with them)
  t.cjk_face_marks()
  clear_shapes()
  let (n1, w1) = marks_both("it’s", 15.0, 400, 0)
  assert_eq(n1, w1)
  assert_true(n1[2 * 4 + 2] < 15.0 * 0.95)
  // a face of another style (italic) is its own
  let (n2, w2) = marks_both("it’s", 15.0, 400, @hostapi.style_italic)
  assert_eq(n2, w2)
}
