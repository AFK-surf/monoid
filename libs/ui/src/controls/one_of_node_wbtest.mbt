// One of a few as a node of the window's tree (one_of_node), with touch and with keyboard and mouse: read out as a
// radio group, each a radio, on or off, drawn lit where pointed at; a press, Space and the arrows choosing, Tab
// stopping at the chosen one alone; more than it lists, a select.

///|
/// The two it is given, by value and words.
let one_of_two : Array[(String, String)] = [("u1", "lin@example.com"), ("u2", "lin@work.example")]

///|
/// The node's on a window of `platform`, choosing among `options` into `now`, read back by it; what it was told it
/// chose, in order.
fn one_of_tester(platform : Int, options : Array[(String, String)], now : @signals.Signal[String], told : Array[String]) -> @ui.Tester {
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=800.0, h=600.0, platform~)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.row(Is(true)) |> ignore
    root.box(fn(col) {
      col.width(Is(Some(360.0))) |> ignore
      one_of_node(col, fn() { now.get() }, fn() { options }, fn(v) {
        told.push(v)
        now.set(v)
      }, label=fn() { "所属账号" })
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// Its radio read out as `label`.
fn one_of_radio(t : @ui.Tester, label : String) -> @ui.SemNode {
  let all = t.all(Radio, label~)
  guard all.length() == 1 else { @halt.saying("\{label}: \{all.length()} radios") }
  all[0]
}

///|
test "one of a few as a node, with touch and with keyboard and mouse: read out as a radio group of radios, the chosen one on; drawn lit where pointed at" {
  for platform in [2, 0] {
    let told : Array[String] = []
    let now = @signals.signal("u1", same=fn(a, b) { a == b })
    let t = one_of_tester(platform, one_of_two, now, told)
    assert_eq(t.all(RadioGroup, label="所属账号").length(), 1, msg="\{platform}")
    let first = one_of_radio(t, "lin@example.com")
    let second = one_of_radio(t, "lin@work.example")
    assert_true(first.check == Some(@view.Check::On), msg="\{platform}: the chosen one on")
    assert_true(second.check == Some(@view.Check::Off), msg="\{platform}: the other off")
    assert_true(first.rect.1 < second.rect.1, msg="\{platform}: in the order given")
    assert_true(words_within(t, first.rect).iter().any(fn(w) { w.has_prefix("lin@example.com@") }), msg="\{platform}: its words")
    if platform == 0 {
      t.leave()
      t.draw()
      let rest = drawn_within(t, second.rect)
      t.move_to(second.rect.0 + 30.0, second.rect.1 + second.rect.3 / 2.0)
      t.run_for(dur_ms)
      assert_true(drawn_within(t, second.rect) != rest, msg="pointed at: lit")
      t.leave()
      t.run_for(dur_ms)
      assert_eq(drawn_within(t, second.rect), rest, msg="left: as at rest")
    }
    assert_eq(told, [], msg="\{platform}")
  }
}

///|
test "one of a few as a node: a press chooses the one pressed, the one chosen pressed again nothing" {
  for platform in [2, 0] {
    let told : Array[String] = []
    let now = @signals.signal("u1", same=fn(a, b) { a == b })
    let t = one_of_tester(platform, one_of_two, now, told)
    let r = one_of_radio(t, "lin@work.example")
    t.tap(r.rect.0 + 30.0, r.rect.1 + r.rect.3 / 2.0)
    t.draw()
    assert_eq(told, ["u2"], msg="\{platform}")
    let r = one_of_radio(t, "lin@work.example")
    assert_true(r.check == Some(@view.Check::On), msg="\{platform}")
    assert_true(one_of_radio(t, "lin@example.com").check == Some(@view.Check::Off), msg="\{platform}")
    t.tap(r.rect.0 + 30.0, r.rect.1 + r.rect.3 / 2.0)
    t.draw()
    assert_eq(told.length(), 1, msg="\{platform}: \{Repr(told)}")
  }
}

///|
test "one of a few as a node: Tab stops at the chosen one, ↓ and ↑ choose the next and the one before round from the ends, Space the one with the focus" {
  let told : Array[String] = []
  let now = @signals.signal("u2", same=fn(a, b) { a == b })
  let t = one_of_tester(0, one_of_two, now, told)
  // Tab to its group: its chosen one
  t.key(@ui.key_tab)
  t.draw()
  let on = one_of_radio(t, "lin@work.example")
  assert_true(t.focused().map(fn(f) { f.rect == on.rect }).unwrap_or(false), msg="\{t.focus_said()}")
  t.key(@ui.key_code_down)
  t.draw()
  t.key(@ui.key_code_up)
  t.draw()
  t.key(@ui.key_code_up)
  t.draw()
  assert_eq(told, ["u1", "u2", "u1"])
  assert_true(one_of_radio(t, "lin@example.com").check == Some(@view.Check::On))
}

///|
test "one of more than it lists, as a node: a select" {
  let many = Array::makei(6, fn(i) { ("u\{i}", "user\{i}@example.com") })
  let told : Array[String] = []
  let now = @signals.signal("u0", same=fn(a, b) { a == b })
  let t = one_of_tester(0, many, now, told)
  assert_eq(t.all(Radio).length(), 0)
  assert_eq(t.all(Button, label="所属账号: user0@example.com").length(), 1)
}
