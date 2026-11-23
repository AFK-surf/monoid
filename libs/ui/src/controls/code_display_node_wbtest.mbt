// A code shown in groups (code_display_node.mbt): cut as @ui.code_field_node groups its boxes, the groups on one line
// 24 apart in the middle, one under another where one line has no room, its words following the code as it changes.

///|
/// `code()` shown in a box `w` wide in a window 600 by 400, the words at `scale`.
fn code_case(code : () -> String, w? : Double = 400.0, scale? : Double = 1.0, groups? : Array[Int] = [3, 3]) -> @ui.Tester {
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=400.0, platform=0)
  t.check_looks(false)
  if scale != 1.0 {
    t.set_font_scale(scale)
  }
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.width(Is(Some(w))) |> ignore
      code_display_node(b, code, groups~) |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// Where `words` are drawn: their left, top, width and height.
fn code_word(t : @ui.Tester, words : String) -> (Double, Double, Double, Double) {
  match t.words().iter().find_first(fn(w) { w.0 == words }) {
    Some(w) => (w.1, w.2, w.3, w.4)
    None => @halt.saying("\{words} is not drawn: \{Repr(t.words().map(fn(w) { w.0 }))}")
  }
}

///|
test "code_segments: cut by its groups where they add up to it, else whole, none for none" {
  assert_eq(code_segments("482915"), ["482", "915"])
  assert_eq(code_segments("48291573", groups=[4, 4]), ["4829", "1573"])
  assert_eq(code_segments(""), [])
  assert_eq(code_segments("48291"), ["48291"])
  assert_eq(code_segments("WXYZ-1234"), ["WXYZ-1234"])
  assert_eq(code_segments("482915", groups=[6, 0]), ["482915"])
  assert_eq(code_segments("482915", groups=[]), ["482915"])
}

///|
test "six figures: two groups of three on one line, 24 apart, in the middle of what holds them" {
  for scale in [1.0, 1.3] {
    let t = code_case(fn() { "482915" }, scale~)
    let at = "scale \{scale}"
    let left = code_word(t, "482")
    let right = code_word(t, "915")
    assert_true((left.1 - right.1).abs() < 1.0, msg="\{at}: \{Repr(left)} \{Repr(right)}")
    assert_true((right.0 - (left.0 + left.2) - 24.0).abs() < 1.0, msg="\{at}: \{Repr(left)} \{Repr(right)}")
    assert_true(((left.0 + right.0 + right.2) / 2.0 - 200.0).abs() < 1.0, msg="\{at}: \{Repr(left)} \{Repr(right)}")
    assert_eq(t.audit(), [], msg=at)
  }
}

///|
test "too narrow for one line: one group under the other, each in the middle" {
  for scale in [1.0, 1.3] {
    let t = code_case(fn() { "482915" }, w=160.0, scale~)
    let at = "scale \{scale}"
    let left = code_word(t, "482")
    let right = code_word(t, "915")
    assert_true(right.1 >= left.1 + left.3, msg="\{at}: \{Repr(left)} \{Repr(right)}")
    for r in [left, right] {
      assert_true((r.0 + r.2 / 2.0 - 80.0).abs() < 1.0, msg="\{at}: \{Repr(r)}")
    }
    assert_eq(t.audit(), [], msg=at)
  }
}

///|
test "its groups follow the code as it changes; four and four where asked" {
  let code = @signals.signal("482915")
  let t = code_case(fn() { code.get() })
  code.set("703619")
  t.draw()
  t.run_for(@ui.move_most_ms)
  let said = t.words().map(fn(w) { w.0 })
  assert_true(said.contains("703") && said.contains("619"), msg="\{Repr(said)}")
  assert_true(!said.contains("482"), msg="\{Repr(said)}")
  let t = code_case(fn() { "48291573" }, groups=[4, 4])
  let left = code_word(t, "4829")
  let right = code_word(t, "1573")
  assert_true((left.1 - right.1).abs() < 1.0 && right.0 > left.0 + left.2, msg="\{Repr(left)} \{Repr(right)}")
}
