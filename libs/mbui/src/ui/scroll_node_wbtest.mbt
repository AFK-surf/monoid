// A column of the window's tree's that scrolls (View::scrolls) keeps the contract of an old view's box kept to a height
// (capped_contract_wbtest's): 200 tall 50 under the top of a window 400 by 300, holding a button of the tree's "上面的按钮"
// (it takes presses, counted, and the focus), a field of an old view's hosted in it, rows taller than it can show,
// another field of an old view's "下面的字段" under them, and a button "最后的按钮" last.

///|
/// How far apart a hand's events come here (a frame's at 60 Hz), and half that.
let hand_step_ms : Double = 16.0

///|
let hand_half_step_ms : Double = 8.0

///|
/// A finger held still this long before it moves.
let hand_held_ms : Double = 80.0

///|
/// What a wheel's turn or a hand's does run to, nothing of it moving after.
let turn_done_ms : Double = 300.0

///|
/// Long past a column's bar showing (its hold, 900, and its fade, 200, after the last that showed it): gone.
let bar_long_gone_ms : Double = 2000.0

///|
/// A part of a bar's coming in (its fade, 200), and the rest of it.
let bar_fade_part_ms : Double = 100.0

///|
let bar_fade_rest_ms : Double = 200.0

///|
/// After a press let go, within the bar's hold (900); then past its hold and fade.
let bar_still_held_ms : Double = 800.0

///|
let bar_past_hold_ms : Double = 500.0

///|
priv struct ScrollNodeCase {
  scroll : @view.Scroll
  pressed : Ref[Int]
}

///|
/// `there`: the column there while it says so (none: always); `over_empty`: over all of the window an old view with
/// nothing of its own over the column (a button of its own under it, at 260).
/// `platform`: the Tester's (0 a desktop's fields, a mouse picking their words; 2 Android's, a finger's tap).
/// `tree_fields`: its two fields the tree's own (ui's field) in the old views' places.
fn scroll_node_case(
  there? : @signals.Signal[Bool],
  over_empty? : Bool = false,
  platform? : Int = 0,
  tree_fields? : Bool = false,
) -> (Tester, ScrollNodeCase) {
  let k : ScrollNodeCase = { scroll: @view.Scroll::new(), pressed: Ref(0) }
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform~)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(gap) { gap.height(Is(Some(50.0))) |> ignore }) |> ignore
    root.show(at_once=true, fn() { there.map(fn(s) { s.get() }).unwrap_or(true) }, fn(v) {
      v
      .width(Is(Some(400.0)))
      .height(Is(Some(200.0)))
      .scrolls(k.scroll, slop=touch_slop(), fn(held) {
        let button = fn(label : String, count : Bool) {
          held.box(fn(b) {
            b
            .width(Is(Some(160.0)))
            .height(Is(Some(40.0)))
            .focusable(Is(true))
            .on_press(fn() { if count { k.pressed.val += 1 } })
            .says(Is(Some(@view.said(Button, label~))))
            .words(Is(label))
            |> ignore
          })
          |> ignore
        }
        button("上面的按钮", true)
        if tree_fields {
          field(held, Field::new(), placeholder="字段").height(Is(Some(40.0))) |> ignore
        } else {
          old(held, fn(c) { c.editor("body/field", placeholder="字段") |> ignore }).height(Is(Some(40.0))) |> ignore
        }
        for i in 0..<8 {
          held.box(fn(r) { r.width(Is(Some(160.0))).height(Is(Some(40.0))).words(Is("第\{i}行")) |> ignore })
          |> ignore
        }
        if tree_fields {
          field(held, Field::new(), placeholder="下面的字段").height(Is(Some(40.0))) |> ignore
        } else {
          old(held, fn(c) { c.editor("body/below", placeholder="下面的字段") |> ignore }).height(Is(Some(40.0))) |> ignore
        }
        button("最后的按钮", false)
      })
      |> ignore
    })
    if over_empty {
      old(root, fn(c) {
        c.box(h=Px(260.0), fn() {  }) |> ignore
        c.button("别处的按钮") |> ignore
      })
      .over(Is(true))
      |> ignore
    }
  })
  t.draw()
  (t, k)
}

///|
fn scroll_node_at(k : ScrollNodeCase) -> Double {
  k.scroll.at(view_tree().unwrap())
}

///|
test "a column of the tree's that scrolls: the wheel over a button in it that takes presses: what it holds scrolls; the button not pressed" {
  let (t, k) = scroll_node_case()
  t.wheel(80.0, 70.0, 40.0)
  assert_eq((scroll_node_at(k), k.pressed.val), (40.0, 0))
}

///|
test "a column of the tree's that scrolls: the wheel over an old view's field hosted in it: what it holds scrolls" {
  let (t, k) = scroll_node_case()
  let at = t.query(TextField).map(fn(f) { f.rect })
  match at {
    Some((x, y, w, h)) => t.wheel(x + w / 2.0, y + h / 2.0, 40.0)
    None => ()
  }
  assert_eq((at is Some(_), scroll_node_at(k)), (true, 40.0))
}

///|
test "a column of the tree's that scrolls: wheeled past its end, kept at its end" {
  let (t, k) = scroll_node_case()
  for _ in 0..<20 {
    t.wheel(80.0, 150.0, 120.0)
  }
  assert_eq(scroll_node_at(k), k.scroll.most())
}

///|
test "a column of the tree's that scrolls: its last button out of sight, Tab to it: the focus on it, scrolled to show it" {
  let (t, k) = scroll_node_case()
  for _ in 0..<12 {
    if t.focused().map(fn(s) { s.label }) == Some("最后的按钮") {
      break
    }
    t.tab()
  }
  t.draw()
  let shown = match t.query(Button, label="最后的按钮") {
    Some(b) => b.rect.1 >= 50.0 - 0.5 && b.rect.1 + b.rect.3 <= 250.0 + 0.5
    None => false
  }
  assert_eq((t.focused().map(fn(s) { s.label }), shown, scroll_node_at(k) > 0.0), (Some("最后的按钮"), true, true))
}

///|
test "a column of the tree's that scrolls: its field scrolled partly out of it: a press where it is drawn over the column none of the field's, nothing scrolled; one in the column its, brought whole into sight" {
  let (t, k) = scroll_node_case()
  t.wheel(80.0, 150.0, 60.0)
  t.draw()
  // (the field drawn at 30 to 70, the column from 50 down)
  let field_at = t.query(TextField).map(fn(f) { f.rect.1 }).unwrap_or(0.0)
  let wheeled = scroll_node_at(k)
  t.tap(80.0, 40.0)
  let over = (t.focused().map(fn(s) { s.role }), scroll_node_at(k))
  t.tap(80.0, 60.0)
  t.draw()
  let within = t.focused().map(fn(s) { s.role })
  let whole = t.query(TextField).map(fn(f) { f.rect.1 >= 50.0 - 0.5 && f.rect.1 + f.rect.3 <= 250.0 + 0.5 })
  assert_eq((wheeled, field_at, over, within, whole), (60.0, 30.0, (None, 60.0), Some(TextField), Some(true)))
}

///|
/// Where the field "下面的字段" is drawn, down the window (its top and foot): the lower of the two read out.
fn below_at(t : Tester) -> (Double, Double)? {
  let fields = t.all(TextField)
  guard fields.length() == 2 else { return None }
  let f = if fields[0].rect.1 > fields[1].rect.1 { fields[0] } else { fields[1] }
  Some((f.rect.1, f.rect.1 + f.rect.3))
}

///|
test "a column of the tree's that scrolls: its old view's field under its rows out of sight, Tab to it: the focus in it, scrolled to show it" {
  let (t, k) = scroll_node_case()
  let out_first = match below_at(t) {
    Some((top, _)) => top >= 250.0
    None => false
  }
  for _ in 0..<12 {
    if t.focused().map(fn(s) { s.role }) == Some(TextField) && below_at(t).map(fn(b) { b.0 < 250.0 }).unwrap_or(false) {
      break
    }
    t.tab()
  }
  t.draw()
  let shown = match below_at(t) {
    Some((top, foot)) => top >= 50.0 - 0.5 && foot <= 250.0 + 0.5
    None => false
  }
  assert_eq((out_first, t.focused().map(fn(s) { s.role }), shown, scroll_node_at(k) > 0.0), (true, Some(TextField), true, true), msg="\{Repr(below_at(t))} \{scroll_node_at(k)}")
}

///|
test "a column of the tree's that scrolls: a finger down on its button, moved up: what it holds dragged, the button not pressed" {
  let (t, k) = scroll_node_case()
  t.drag(80.0, 70.0, 80.0, 10.0)
  assert_eq((scroll_node_at(k) >= 40.0, k.pressed.val), (true, 0), msg="\{scroll_node_at(k)}")
}

///|
test "a column of the tree's that scrolls: a finger down on its button, moved across: nothing scrolled, the button pressed where it is let go on it" {
  let (t, k) = scroll_node_case()
  t.drag(40.0, 70.0, 120.0, 72.0)
  assert_eq((scroll_node_at(k), k.pressed.val), (0.0, 1))
}

///|
test "a column of the tree's that scrolls, a finger's fields (Android's): a finger down on a field in it (an old view's, the tree's), moved up: what it holds dragged, the field given no focus" {
  for tree_fields in [false, true] {
    let (t, k) = scroll_node_case(platform=2, tree_fields~)
    let (x, y, w, h) = t.query(TextField).unwrap().rect
    t.drag(x + w / 2.0, y + h / 2.0, x + w / 2.0, y + h / 2.0 - 60.0)
    assert_eq(
      (scroll_node_at(k) >= 40.0, t.focused().map(fn(s) { s.role }), t.ime().0),
      (true, None, false),
      msg="\{tree_fields}: \{scroll_node_at(k)}",
    )
  }
}

///|
test "a column of the tree's that scrolls, a finger's fields (Android's): a field in it (an old view's, the tree's) tapped: the focus its, the keyboard told, nothing scrolled" {
  for tree_fields in [false, true] {
    let (t, k) = scroll_node_case(platform=2, tree_fields~)
    let (x, y, w, h) = t.query(TextField).unwrap().rect
    t.tap(x + w / 2.0, y + h / 2.0)
    t.draw()
    assert_eq((scroll_node_at(k), t.focused().map(fn(s) { s.role }), t.ime().0), (0.0, Some(TextField), true), msg="\{tree_fields}")
  }
}

///|
test "a column of the tree's that scrolls, a desktop's fields: the pointer down on a field in it (an old view's, the tree's), moved up: its words picked, nothing scrolled" {
  for tree_fields in [false, true] {
    let (t, k) = scroll_node_case(tree_fields~)
    let (x, y, w, h) = t.query(TextField).unwrap().rect
    t.drag(x + w / 2.0, y + h / 2.0, x + w / 2.0, y + h / 2.0 - 60.0)
    assert_eq((scroll_node_at(k), t.focused().map(fn(s) { s.role })), (0.0, Some(TextField)), msg="\{tree_fields}")
  }
}

///|
test "a column of the tree's that scrolls, a finger's fields: its field (an old view's, the tree's) with the focus, a finger down on a row, moved up: what it holds dragged, the field let go of" {
  for tree_fields in [false, true] {
    let (t, k) = scroll_node_case(platform=2, tree_fields~)
    let (x, y, w, h) = t.query(TextField).unwrap().rect
    t.tap(x + w / 2.0, y + h / 2.0)
    let had = t.focused().map(fn(s) { s.role })
    t.drag(80.0, 220.0, 80.0, 140.0)
    assert_eq((had, scroll_node_at(k) > 0.0, t.focused().map(fn(s) { s.role })), (Some(TextField), true, None), msg="\{tree_fields}")
  }
}

///|
/// A column 200 tall 50 under the window's top holding one old view hosted in it: a field "上面的字段", `rows` rows (8,
/// taller than the column can show), a field "下面的字段" under them, given the focus as it is built while `below` says
/// so (once each time it comes to).
fn scroll_one_island_case(
  rows? : @signals.Signal[Int] = @signals.signal(8, same=fn(a, b) { a == b }),
  below? : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b }),
) -> (Tester, @view.Scroll) {
  let scroll = @view.Scroll::new()
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(gap) { gap.height(Is(Some(50.0))) |> ignore }) |> ignore
    root.box(fn(v) {
      v
      .width(Is(Some(400.0)))
      .height(Is(Some(200.0)))
      .scrolls(scroll, fn(held) {
        old(held, fn(c) {
          c.editor("one/above", placeholder="上面的字段") |> ignore
          for i in 0..<rows.get() {
            c.box(w=Px(160.0), h=Px(40.0), fn() { c.text("岛第\{i}行") |> ignore }) |> ignore
          }
          c.editor("one/below", placeholder="下面的字段") |> ignore
          if below.get() && !c.has_focus(c.id("one/below")) {
            c.focus_editor("one/below")
          }
        })
        // (as tall as what it builds: two fields and its rows, 40 each; an old view hosted says nothing of its height)
        .height(By(fn() { Some(40.0 * (rows.get() + 2).to_double()) }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  (t, scroll)
}

///|
test "a column of the tree's that scrolls, one old view in it with a field over its rows and one under them: Tab from the one to the other: the lower brought into sight, not the old view's top" {
  let (t, scroll) = scroll_one_island_case()
  let out_first = match below_at(t) {
    Some((top, _)) => top >= 250.0
    None => false
  }
  for _ in 0..<6 {
    if t.focused().map(fn(s) { s.role }) == Some(TextField) && below_at(t).map(fn(b) { b.0 < 250.0 }).unwrap_or(false) {
      break
    }
    t.tab()
  }
  t.draw()
  let shown = match below_at(t) {
    Some((top, foot)) => top >= 50.0 - 0.5 && foot <= 250.0 + 0.5
    None => false
  }
  assert_eq((out_first, shown, scroll.at(view_tree().unwrap()) > 0.0), (true, true, true), msg="\{Repr(below_at(t))} \{scroll.at(view_tree().unwrap())}")
}

///|
test "a column of the tree's that scrolls: one long move from a finger down on a row, taken over then: as far as an old view's box kept to a height goes on the same move" {
  // (the old one's: 200 tall at the window's top)
  let (old_t, _) = capped_case()
  old_t.touch(0, 80.0, 150.0)
  old_t.touch(1, 80.0, 90.0)
  let old_went = capped_at()
  old_t.touch(2, 80.0, 90.0)
  // (the tree's: 50 under it, the same point in it)
  let (t, k) = scroll_node_case()
  t.touch(0, 80.0, 200.0)
  t.touch(1, 80.0, 140.0)
  let went = scroll_node_at(k)
  t.touch(2, 80.0, 140.0)
  assert_eq((went, old_went > 0.0), (old_went, true), msg="\{went} \{old_went}")
}

///|
test "a column of the tree's that scrolls under an old view over all of the window with nothing of its own there: a finger down on a row, moved up: what it holds dragged" {
  let (t, k) = scroll_node_case(over_empty=true)
  t.drag(80.0, 200.0, 80.0, 120.0)
  assert_true(scroll_node_at(k) > 0.0, msg="\{scroll_node_at(k)}")
}

///|
test "a column of the tree's that scrolls let go and another made in its place as a finger is held down on it: the move after taken over by none, the new one where it was made" {
  let there = @signals.signal(true, same=fn(a, b) { a == b })
  let (t, k) = scroll_node_case(there~)
  t.touch(0, 80.0, 200.0)
  there.set(false)
  t.draw()
  there.set(true)
  t.draw()
  t.touch(1, 80.0, 140.0)
  t.touch(1, 80.0, 100.0)
  let at = scroll_node_at(k)
  t.touch(2, 80.0, 100.0)
  assert_eq(at, 0.0)
}

///|
/// Whether the field "下面的字段" shows whole in the column (50 to 250 down).
fn below_whole(t : Tester) -> Bool {
  match below_at(t) {
    Some((top, foot)) => top >= 50.0 - 0.5 && foot <= 250.0 + 0.5
    None => false
  }
}

///|
test "a column of the tree's that scrolls, one old view in it: its lower field given the focus as the old view is first built: brought into sight in that first frame" {
  let (t, scroll) = scroll_one_island_case(below=@signals.signal(true, same=fn(a, b) { a == b }))
  // (as of its first frame)
  assert_eq((t.focused().map(fn(s) { s.role }), below_whole(t), scroll.at(view_tree().unwrap()) > 0.0), (Some(TextField), true, true), msg="\{Repr(below_at(t))}")
}

///|
test "a column of the tree's that scrolls, one old view in it: rows added over its lower field as it is given the focus, in one change: brought into sight where it is laid out then, in the frame after it" {
  let rows = @signals.signal(8, same=fn(a, b) { a == b })
  let below = @signals.signal(false, same=fn(a, b) { a == b })
  let (t, scroll) = scroll_one_island_case(rows~, below~)
  @signals.start_batch()
  rows.set(12)
  below.set(true)
  @signals.end_batch()
  // (as of the one frame after)
  t.draw()
  assert_eq((t.focused().map(fn(s) { s.role }), below_whole(t), scroll.at(view_tree().unwrap()) > 300.0), (Some(TextField), true, true), msg="\{Repr(below_at(t))} \{scroll.at(view_tree().unwrap())}")
}

///|
test "a node of the tree's taking over holds for something other than scrolling (moved across), an old view's field with the focus and a finger's keyboard: taken over, the field keeps it" {
  let held = Ref(0)
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=2)
  t.check_looks(false)
  set_view_app(fn(root) {
    old(root, fn(c) { c.editor("keep/field", placeholder="字段") |> ignore }).height(Is(Some(40.0))) |> ignore
    root.box(fn(b) {
      b
      .width(Is(Some(400.0)))
      .height(Is(Some(100.0)))
      .claims(fn(dx, dy) { dx.abs() > 10.0 && dx.abs() > dy.abs() })
      .on_drag(fn(_) { held.val += 1 })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let (x, y, w, h) = t.query(TextField).unwrap().rect
  t.tap(x + w / 2.0, y + h / 2.0)
  let had = t.focused().map(fn(s) { s.role })
  t.drag(100.0, 90.0, 200.0, 90.0)
  assert_eq((had, held.val > 0, t.focused().map(fn(s) { s.role })), (Some(TextField), true, Some(TextField)))
}

///|
test "a column of the tree's that scrolls: the wheel across more than up or down over it: nothing of it moved, what holds it given it; an old view's box kept to a height moves by none of the same" {
  let (old_t, _) = capped_case()
  finger_wheel(80.0, 100.0, 60.0, 10.0, 0)
  old_t.draw()
  let old_at = capped_at()
  let k : ScrollNodeCase = { scroll: @view.Scroll::new(), pressed: Ref(0) }
  let outer : Ref[(Double, Double)] = Ref((0.0, 0.0))
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(o) {
      o
      .width(Is(Some(400.0)))
      .height(Is(Some(300.0)))
      .on_wheel_moves(fn(w) {
        outer.val = (outer.val.0 + w.dx, outer.val.1 + w.dy)
        true
      })
      |> ignore
      o.box(fn(v) {
        v
        .height(Is(Some(200.0)))
        .scrolls(k.scroll, fn(held) {
          for _ in 0..<10 {
            held.box(fn(r) { r.width(Is(Some(400.0))).height(Is(Some(40.0))) |> ignore }) |> ignore
          }
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  finger_wheel(80.0, 100.0, 60.0, 10.0, 0)
  t.draw()
  assert_eq((scroll_node_at(k), outer.val, old_at), (0.0, (60.0, 10.0), 0.0))
}

///|
/// A finger down on a row at (80, `y`), moved `moves` times 30 up 16 ms apart, let go 8 ms on and 15 further as it goes
/// (or held still `wait` ms where it is, then let go there); where what scrolls stands as it is let go, and 2 s on.
fn flick(t : Tester, y : Double, moves : Int, wait : Double, at : () -> Double) -> (Double, Double) {
  t.touch(0, 80.0, y)
  for i in 1..=moves {
    t.run_for(hand_step_ms)
    t.touch(1, 80.0, y - 30.0 * i.to_double())
  }
  // (let go half a move on, as it goes, a frame after; held still `wait` first, let go where it stopped)
  if wait > 0.0 {
    t.run_for(wait)
    t.touch(2, 80.0, y - 30.0 * moves.to_double())
  } else {
    t.run_for(hand_half_step_ms)
    t.touch(2, 80.0, y - 30.0 * moves.to_double() - 15.0)
  }
  let let_go = at()
  t.run_for(bar_long_gone_ms)
  (let_go, at())
}

///|
test "a column of the tree's that scrolls: one move past the slop, let go a frame on as it goes: flung on, as an old view's box kept to a height is by the same events" {
  let (old_t, _) = capped_case()
  let (old_go, old_rest) = flick(old_t, 150.0, 1, 0.0, capped_at)
  let (t, k) = scroll_node_case(platform=2)
  let (go, rest) = flick(t, 200.0, 1, 0.0, fn() { scroll_node_at(k) })
  assert_eq((rest > go, old_rest > old_go), (true, true), msg="\{go} \{rest} \{old_go} \{old_rest}")
}

///|
test "a column of the tree's that scrolls: two moves, held still past a pause, then let go: not flung, as an old view's box kept to a height is not by the same events" {
  let (old_t, _) = capped_case()
  let (old_go, old_rest) = flick(old_t, 150.0, 2, 80.0, capped_at)
  let (t, k) = scroll_node_case(platform=2)
  let (go, rest) = flick(t, 200.0, 2, 80.0, fn() { scroll_node_at(k) })
  assert_eq((rest, old_rest), (go, old_go), msg="\{go} \{rest} \{old_go} \{old_rest}")
}

///|
test "a column of the tree's that scrolls: held still past a pause, moved a little within the slop, then fast past it and let go a frame on as it goes: flung on by the moves since the pause, as an old view's box kept to a height is" {
  let go = fn(t : Tester, y : Double, at : () -> Double) {
    t.touch(0, 80.0, y)
    t.run_for(hand_held_ms)
    t.touch(1, 80.0, y - 3.0)
    t.run_for(hand_step_ms)
    t.touch(1, 80.0, y - 40.0)
    t.run_for(hand_half_step_ms)
    t.touch(2, 80.0, y - 58.0)
    let let_go = at()
    t.run_for(bar_long_gone_ms)
    (let_go, at())
  }
  let (old_t, _) = capped_case()
  let (old_go, old_rest) = go(old_t, 150.0, capped_at)
  let (t, k) = scroll_node_case(platform=2)
  let (now, rest) = go(t, 200.0, fn() { scroll_node_at(k) })
  assert_eq((rest > now, old_rest > old_go), (true, true), msg="\{now} \{rest} \{old_go} \{old_rest}")
}

///|
test "a column of the tree's that scrolls: one move past the slop, let go a frame on where it stopped: flung on at how fast that move went, the lift saying its place again no move of it (as Android's VelocityTracker takes no ACTION_UP), as an old view's box kept to a height is by the same events" {
  let go = fn(t : Tester, y : Double, at : () -> Double) {
    t.touch(0, 80.0, y)
    t.run_for(hand_step_ms)
    t.touch(1, 80.0, y - 30.0)
    t.run_for(hand_half_step_ms)
    t.touch(2, 80.0, y - 30.0)
    let let_go = at()
    t.run_for(bar_long_gone_ms)
    (let_go, at())
  }
  let (old_t, _) = capped_case()
  let (old_go, old_rest) = go(old_t, 150.0, capped_at)
  let (t, k) = scroll_node_case(platform=2)
  let (now, rest) = go(t, 200.0, fn() { scroll_node_at(k) })
  assert_eq((rest > now, old_rest > old_go), (true, true), msg="\{now} \{rest} \{old_go} \{old_rest}")
}

///|
test "an old view's box kept to a height at its end, what it holds made shorter, then as long again: at the end of the shorter, as the tree's column is" {
  let rows = @signals.signal(10, same=fn(a, b) { a == b })
  let t = Tester::new(fn(c) {
    c.capped("body", 200.0, fn() {
      for i in 0..<rows.get() {
        c.box(w=Px(160.0), h=Px(40.0), fn() { c.text("第\{i}行") |> ignore }) |> ignore
      }
    })
    |> ignore
  }, w=400.0, h=300.0, platform=0)
  t.draw()
  for _ in 0..<10 {
    t.wheel(80.0, 100.0, 120.0)
  }
  let end = capped_at()
  rows.set(6)
  t.draw()
  let short = capped_at()
  rows.set(10)
  t.draw()
  assert_eq((end, short, capped_at()), (200.0, 40.0, 40.0))
}

///|
test "a column of the tree's that scrolls, with these bars, a mouse over it: scrolled, what it holds faded towards its foot as drawn, its bar's thumb along that edge none of it" {
  let scroll = @view.Scroll::plain()
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(v) {
      v
      .width(Is(Some(400.0)))
      .height(Is(Some(200.0)))
      .scrolls(scroll, bar=tree_scroll_bar(), fn(held) {
        for _ in 0..<10 {
          held.box(fn(r) { r.width(Is(Some(400.0))).height(Is(Some(40.0))).ground(Is(0x808080FFL)) |> ignore }) |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.move_to(200.0, 100.0)
  t.wheel(200.0, 100.0, 40.0)
  t.run_for(turn_done_ms)
  let drawn = t.drawn_instances()
  // (its thumb: as wide as these bars', along the right; a row: as wide as the column)
  let thumb = drawn.filter(fn(a) { a[2] == scroll_bar_size && a[0] > 390.0 })
  let rows = drawn.filter(fn(a) { a[2] == 400.0 && a[1] > 120.0 && a[1] < 200.0 })
  let rows_fade = rows.iter().any(fn(a) { a[55] > 0.0 })
  let thumb_clear = thumb.iter().all(fn(a) { a[53] == 0.0 && a[55] == 0.0 })
  assert_eq((thumb.length(), rows_fade, thumb_clear), (1, true, true), msg="\{Repr(thumb.map(fn(a) { (a[0], a[1], a[3], a[53], a[55]) }))}")
}

///|
/// The bar's thumb drawn last frame (w = scroll_bar_size, along the right past `x`): its opacity, if one is.
fn thumb_opacity(t : Tester, x : Double) -> Double? {
  t.drawn_order().iter().find_first(fn(d) { d.0 == 0 && d.3 == scroll_bar_size && d.1 > x }).map(fn(d) { d.5 })
}

///|
test "a column of the tree's that scrolls, with these bars, and an old view's box kept to a height: the pointer come along their right edge, each bar coming in as the other, from nothing" {
  let came = fn(t : Tester, x : Double, y : Double) {
    t.move_to(x - 40.0, y)
    t.run_for(bar_long_gone_ms)
    t.move_to(x, y)
    let first = thumb_opacity(t, 380.0).unwrap_or(0.0)
    t.run_for(bar_fade_part_ms)
    let mid = thumb_opacity(t, 380.0).unwrap_or(0.0)
    t.run_for(bar_fade_rest_ms)
    (first, mid, thumb_opacity(t, 380.0).unwrap_or(0.0))
  }
  let (old_t, _) = capped_case()
  // (along the edge, under its thumb: not over it, as the thumb is at the top)
  let old = came(old_t, 395.0, 150.0)
  let scroll = @view.Scroll::new()
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(v) {
      v
      .width(Is(Some(400.0)))
      .height(Is(Some(200.0)))
      .scrolls(scroll, bar=tree_scroll_bar(), fn(held) {
        for _ in 0..<10 {
          held.box(fn(r) { r.width(Is(Some(400.0))).height(Is(Some(40.0))) |> ignore }) |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let new = came(t, 395.0, 150.0)
  assert_eq((new.0 < 0.05, (new.1 - old.1).abs() < 0.02, (new.2 - old.2).abs() < 0.02, old.1 > 0.05, old.1 < old.2), (true, true, true, true, true), msg="\{Repr(new)} \{Repr(old)}")
}

///|
test "a column of the tree's that scrolls in one that does too, with these bars: the inner's thumb at the outer's foot faded by the outer as what the outer holds is, none by its own" {
  let outer = @view.Scroll::plain()
  let inner = @view.Scroll::plain()
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(o) {
      o
      .width(Is(Some(400.0)))
      .height(Is(Some(200.0)))
      .scrolls(outer, bar=tree_scroll_bar(), fn(oh) {
        oh.box(fn(gap) { gap.height(Is(Some(120.0))) |> ignore }) |> ignore
        oh.box(fn(i) {
          i
          .width(Is(Some(360.0)))
          .height(Is(Some(100.0)))
          .scrolls(inner, bar=tree_scroll_bar(), fn(ih) {
            for _ in 0..<10 {
              ih.box(fn(r) { r.width(Is(Some(360.0))).height(Is(Some(40.0))).ground(Is(0x808080FFL)) |> ignore }) |> ignore
            }
          })
          |> ignore
        })
        |> ignore
        oh.box(fn(gap) { gap.height(Is(Some(400.0))) |> ignore }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.move_to(200.0, 150.0)
  // (the inner to its end: its thumb at its foot, 220 down, past the outer's at 200)
  for _ in 0..<3 {
    t.wheel(200.0, 150.0, 120.0)
  }
  t.run_for(turn_done_ms)
  let thumbs = t.drawn_instances().filter(fn(a) { a[2] == scroll_bar_size && a[0] > 340.0 && a[0] < 360.0 })
  // (faded by the outer towards its foot at 200; the inner's own, towards 220, none of it)
  let by_outer = thumbs.iter().all(fn(a) { a[55] > 0.0 && (a[54] - 200.0).abs() < 0.5 })
  assert_eq((thumbs.length(), by_outer), (1, true), msg="\{Repr(thumbs.map(fn(a) { (a[0], a[1], a[3], a[54], a[55]) }))}")
}

///|
/// A finger's flick on what scrolls at (200, `y`) (as Tester::touch's events, the host saying a finger), then, the hand
/// a mouse's from here, the pointer at (200, `y`) over it away from its edge, the fling stopped soon by a press there,
/// let go, the pointer left there: whether it went on after the flick, whether it went on as the pointer came, whether
/// the bar showed then, then whether it shows bar_still_held_ms after the press, and whether it does bar_past_hold_ms
/// more after.
fn flick_to_mouse(t : Tester, y : Double, at : () -> Double) -> (Bool, Bool, Bool, Bool, Bool) {
  t.host_says_finger(Some(true))
  t.touch(0, 200.0, y)
  t.run_for(hand_step_ms)
  t.touch(1, 200.0, y - 30.0)
  t.run_for(hand_step_ms)
  t.touch(1, 200.0, y - 60.0)
  t.run_for(hand_half_step_ms)
  t.touch(2, 200.0, y - 75.0)
  let let_go = at()
  t.run_for(hand_step_ms)
  let went_on = at() > let_go
  t.host_says_finger(Some(false))
  t.move_to(200.0, y)
  let before = at()
  t.run_for(hand_step_ms)
  let still = at() > before
  let bar = thumb_opacity(t, 380.0).unwrap_or(0.0) > 0.0
  t.touch(0, 200.0, y)
  t.touch(2, 200.0, y)
  t.run_for(bar_still_held_ms)
  let shown = thumb_opacity(t, 380.0).unwrap_or(0.0) > 0.0
  t.run_for(bar_past_hold_ms)
  let gone = thumb_opacity(t, 380.0).unwrap_or(0.0) == 0.0
  (went_on, still, bar, shown, gone)
}

///|
test "a column of the tree's that scrolls, with these bars: flung by a finger, a mouse's from there, the fling stopped soon by a press: its bar showing and going as an old view's box kept to a height's does by the same events" {
  let (old_t, _) = capped_case()
  let old = flick_to_mouse(old_t, 150.0, capped_at)
  // (each at rest at its end, the old one's before the next is made)
  assert_true(old_t.at_rest(), msg=old_t.rest_why())
  let scroll = @view.Scroll::new()
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(v) {
      v
      .width(Is(Some(400.0)))
      .height(Is(Some(200.0)))
      .scrolls(scroll, bar=tree_scroll_bar(), slop=touch_slop(), fn(held) {
        for _ in 0..<10 {
          held.box(fn(r) { r.width(Is(Some(400.0))).height(Is(Some(40.0))) |> ignore }) |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let new = flick_to_mouse(t, 150.0, fn() { scroll.at(view_tree().unwrap()) })
  assert_true(t.at_rest(), msg=t.rest_why())
  assert_eq((new, old.0), (old, true), msg="\{Repr(new)} \{Repr(old)}")
}

///|
/// The thumbs drawn last frame along the right past `x` (their top and foot), top to bottom.
fn thumbs_at(t : Tester, x : Double) -> Array[(Double, Double)] {
  t.drawn_order().filter(fn(d) { d.0 == 0 && d.3 == scroll_bar_size && d.1 > x && d.5 > 0.0 }).map(fn(d) { (d.2, d.2 + d.4) })
}

///|
test "an old view's box kept to a height in another as wide, and a column of the tree's in another as wide, with these bars: the pointer come along the inner's edge, none shown before, the same bars shown as the old's" {
  let old_t = Tester::new(fn(c) {
    c.box(h=Px(50.0), fn() {  }) |> ignore
    c.capped("outer", 200.0, fn() {
      c.capped("inner", 100.0, fn() {
        for i in 0..<10 {
          c.box(w=Px(160.0), h=Px(40.0), fn() { c.text("内\{i}") |> ignore }) |> ignore
        }
      })
      |> ignore
      for i in 0..<10 {
        c.box(w=Px(160.0), h=Px(40.0), fn() { c.text("外\{i}") |> ignore }) |> ignore
      }
    })
    |> ignore
  }, w=400.0, h=300.0, platform=0)
  old_t.draw()
  let near = fn(t : Tester) {
    t.move_to(200.0, 100.0)
    t.run_for(bar_long_gone_ms)
    let before = thumbs_at(t, 380.0)
    t.move_to(395.0, 100.0)
    t.run_for(turn_done_ms)
    (before, thumbs_at(t, 380.0))
  }
  let old = near(old_t)
  let (outer, inner) = (@view.Scroll::new(), @view.Scroll::new())
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(gap) { gap.height(Is(Some(50.0))) |> ignore }) |> ignore
    root.box(fn(o) {
      o
      .width(Is(Some(400.0)))
      .height(Is(Some(200.0)))
      .scrolls(outer, bar=tree_scroll_bar(), fn(oh) {
        oh.box(fn(i) {
          i
          .width(Is(Some(400.0)))
          .height(Is(Some(100.0)))
          .scrolls(inner, bar=tree_scroll_bar(), fn(ih) {
            for _ in 0..<10 {
              ih.box(fn(r) { r.width(Is(Some(400.0))).height(Is(Some(40.0))) |> ignore }) |> ignore
            }
          })
          |> ignore
        })
        |> ignore
        for _ in 0..<10 {
          oh.box(fn(r) { r.width(Is(Some(400.0))).height(Is(Some(40.0))) |> ignore }) |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let new = near(t)
  // (each shown the inner's, short (100 of 400 shows), or the outer's, long (200 of 500))
  let whose = fn(th : Array[(Double, Double)]) { th.map(fn(r) { r.1 - r.0 < 50.0 }) }
  assert_eq((new.0.length(), whose(new.1), old.0.length()), (0, whose(old.1), 0), msg="\{Repr(new)} \{Repr(old)}")
}

///|
test "a column of the tree's that scrolls in another, with these bars: the inner scrolled out over the outer's top, the pointer where the inner's edge would be there: no bar of the inner's shown" {
  let (outer, inner) = (@view.Scroll::new(), @view.Scroll::new())
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(gap) { gap.height(Is(Some(100.0))) |> ignore }) |> ignore
    root.box(fn(o) {
      o
      .width(Is(Some(400.0)))
      .height(Is(Some(150.0)))
      .scrolls(outer, bar=tree_scroll_bar(), fn(oh) {
        oh.box(fn(i) {
          i
          .width(Is(Some(360.0)))
          .height(Is(Some(100.0)))
          .scrolls(inner, bar=tree_scroll_bar(), fn(ih) {
            for _ in 0..<10 {
              ih.box(fn(r) { r.width(Is(Some(360.0))).height(Is(Some(40.0))) |> ignore }) |> ignore
            }
          })
          |> ignore
        })
        |> ignore
        for _ in 0..<10 {
          oh.box(fn(r) { r.width(Is(Some(400.0))).height(Is(Some(40.0))) |> ignore }) |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  // (the outer moved on 80 by the wheel over its own rows: the inner at 20 to 120 down the window, its edge over the
  // outer's top, at 100, from 20 to 100)
  t.move_to(200.0, 220.0)
  t.wheel(200.0, 220.0, 80.0)
  t.run_for(bar_long_gone_ms)
  t.move_to(355.0, 60.0)
  t.run_for(turn_done_ms)
  assert_eq(thumbs_at(t, 340.0).filter(fn(th) { th.0 < 100.0 }), [])
}

///|
test "a column of the tree's that scrolls and an old view's box kept to a height, as tall and holding as much, with these bars: their thumbs where each other's are; the pointer just under each, in what takes it round it: each lit as the other" {
  let lit = fn(t : Tester) {
    t.move_to(200.0, 100.0)
    t.wheel(200.0, 100.0, 40.0)
    t.run_for(turn_done_ms)
    let th = t.drawn_order().filter(fn(d) { d.0 == 0 && d.3 == scroll_bar_size && d.5 > 0.0 })
    guard th.length() == 1 else { return (th.map(fn(d) { (d.1, d.2, d.4) }), 0.0) }
    let (x, y, h) = (th[0].1, th[0].2, th[0].4)
    // (2 under its foot, in the 4 round it the pointer takes it in)
    t.move_to(x + 1.5, y + h + 2.0)
    t.run_for(turn_done_ms)
    let o = t.drawn_order().filter(fn(d) { d.0 == 0 && d.3 == scroll_bar_size && d.5 > 0.0 }).map(fn(d) { d.5 })
    ([(x, y, h)], o.get(0).unwrap_or(0.0))
  }
  let old_t = Tester::new(fn(c) {
    c.capped("same", 200.0, fn() {
      for i in 0..<10 {
        c.box(w=Px(400.0), h=Px(40.0), fn() { c.text("行\{i}") |> ignore }) |> ignore
      }
    })
    |> ignore
  }, w=400.0, h=300.0, platform=0)
  old_t.draw()
  let old = lit(old_t)
  let scroll = @view.Scroll::new()
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(v) {
      v
      .width(Is(Some(400.0)))
      .height(Is(Some(200.0)))
      .scrolls(scroll, bar=tree_scroll_bar(), fn(held) {
        for _ in 0..<10 {
          held.box(fn(r) { r.width(Is(Some(400.0))).height(Is(Some(40.0))) |> ignore }) |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let new = lit(t)
  assert_eq((new.0, (new.1 - old.1).abs() < 0.02, old.1 > 0.4), (old.0, true, true), msg="\{Repr(new)} \{Repr(old)}")
}

///|
test "a column of the tree's that scrolls and an old view's box kept to a height, what each holds 0.5, 1 and 2 past it, with these bars: each scrolled as far as that, and a bar the old's has alone" {
  let one = fn(over : Double) {
    // (the old's)
    let old_t = Tester::new(fn(c) {
      c.capped("over", 200.0, fn() { c.box(w=Px(400.0), h=Px(200.0 + over), fn() {  }) |> ignore }) |> ignore
    }, w=400.0, h=300.0, platform=0)
    old_t.draw()
    old_t.move_to(200.0, 100.0)
    old_t.wheel(200.0, 100.0, 40.0)
    old_t.run_for(turn_done_ms)
    let old = (capped_id_at("over"), thumbs_at(old_t, 380.0).length())
    // (the tree's)
    let scroll = @view.Scroll::new()
    let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
    t.check_looks(false)
    set_view_app(fn(root) {
      root.box(fn(v) {
        v
        .width(Is(Some(400.0)))
        .height(Is(Some(200.0)))
        .scrolls(scroll, bar=tree_scroll_bar(), fn(held) {
          held.box(fn(r) { r.width(Is(Some(400.0))).height(Is(Some(200.0 + over))) |> ignore }) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    t.draw()
    t.move_to(200.0, 100.0)
    t.wheel(200.0, 100.0, 40.0)
    t.run_for(turn_done_ms)
    ((scroll.most(), scroll_node_at_of(scroll)), thumbs_at(t, 380.0).length(), old)
  }
  let got = [one(0.5), one(1.0), one(2.0)]
  // (as far as each goes, the same: what it holds past it, laid out so)
  let ranges = got.map(fn(g) { (g.0.0, g.0.1, g.2.0) })
  let bars = got.map(fn(g) { (g.1, g.2.1) })
  assert_eq((ranges, bars), ([(0.5, 0.5, 0.5), (1.0, 1.0, 1.0), (2.0, 2.0, 2.0)], [(0, 0), (0, 0), (1, 1)]), msg="\{Repr(got)}")
}

///|
fn capped_id_at(key : String) -> Double {
  match sideways.get(g().capped_id(key)) {
    Some(s) => s.x
    None => -1.0
  }
}

///|
fn scroll_node_at_of(s : @view.Scroll) -> Double {
  s.at(view_tree().unwrap())
}

///|
/// A field `placeholder` in `v`, 40 tall: the tree's own (ui's field) where `tree_fields`, else an old view's.
fn scroll_node_field(v : @view.View, tree_fields : Bool, placeholder : String) -> Unit {
  if tree_fields {
    field(v, Field::new(), placeholder~).height(Is(Some(40.0))) |> ignore
  } else {
    old(v, fn(c) { c.editor("field/\{placeholder}", placeholder~) |> ignore }).height(Is(Some(40.0))) |> ignore
  }
}

///|
/// A column of 8 choices "选项 0".. (each 40 tall) 150 tall in `v`, scrolling as `s` says, for what `for_in` holds.
fn scroll_node_choices(v : @view.View, s : @view.Scroll, for_in? : @view.NodeId) -> Unit {
  v
  .width(Is(Some(400.0)))
  .height(Is(Some(150.0)))
  .scrolls(s, slop=touch_slop(), for_in?, fn(held) {
    for i in 0..<8 {
      held.box(fn(r) { r.width(Is(Some(160.0))).height(Is(Some(40.0))).words(Is("选项 \{i}")) |> ignore })
      |> ignore
    }
  })
  |> ignore
}

///|
test "a column of the tree's that scrolls a field's choices (View::scrolls' for_in), a finger's fields (Android's): a finger scrolling them keeps that field's keyboard, but lets another field's go" {
  for tree_fields in [false, true] {
    for own in [true, false] {
      let scroll = @view.Scroll::new()
      let t = Tester::new(fn(_c) {  }, w=400.0, h=400.0, platform=2, pointing=Finger)
      t.check_looks(false)
      set_view_app(fn(root) {
        let holder = root.box(fn(h) { scroll_node_field(h, tree_fields, "查找") })
        scroll_node_field(root, tree_fields, "其他")
        root.box(fn(v) { scroll_node_choices(v, scroll, for_in=holder.id()) }) |> ignore
      })
      t.draw()
      t.tap_text(if own { "查找" } else { "其他" })
      t.draw()
      assert_true(t.ime().0, msg="\{tree_fields} \{own}: the chosen field starts with the keyboard")
      let (x, y) = t.find("选项 2").unwrap()
      t.drag(x + 5.0, y + 5.0, x + 5.0, y - 70.0)
      t.draw()
      assert_eq((scroll.at(view_tree().unwrap()) > 0.0, t.ime().0), (true, own), msg="\{tree_fields} \{own}")
    }
  }
}

///|
test "a column of the tree's that scrolls in a layer that leaves what is typed to a field outside it (View::leaves_typing), a finger's fields (Android's): a finger scrolling it keeps the field under the layer its keyboard, but lets a field in the layer's go" {
  for tree_fields in [false, true] {
    for modal in [true, false] {
      let scroll = @view.Scroll::new()
      let open = @signals.signal(false)
      let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=2, pointing=Finger)
      t.check_looks(false)
      set_view_app(fn(root) {
        root.box(fn(gap) { gap.height(Is(Some(250.0))) |> ignore }) |> ignore
        scroll_node_field(root, tree_fields, "底下的字段")
        root.show(at_once=true, fn() { open.get() }, fn(layer) {
          layer.over(Is(true)).stacked(Is(5)).modal(Is(modal)).presses(Is(true)).leaves_typing() |> ignore
          scroll_node_field(layer, tree_fields, "层里的字段")
          layer.box(fn(v) { scroll_node_choices(v, scroll) }) |> ignore
        })
      })
      t.draw()
      let case = "\{tree_fields} \{modal}"
      // (the field under it with the keyboard, the layer opened over it)
      t.tap_text("底下的字段")
      t.draw()
      assert_true(t.ime().0, msg="\{case}: the field under it starts with the keyboard")
      open.set(true)
      t.draw()
      let (x, y) = t.find("选项 2").unwrap()
      t.drag(x + 5.0, y + 5.0, x + 5.0, y - 70.0)
      t.draw()
      let scrolled = scroll.at(view_tree().unwrap())
      assert_eq((scrolled > 0.0, t.ime().0, g().field_focused()), (true, true, true), msg="\{case}: the field under it")
      // (the field in the layer given the keyboard: scrolled, let go)
      t.tap_text("层里的字段")
      t.draw()
      assert_true(t.ime().0, msg="\{case}: the field in the layer takes the keyboard")
      let (x, y) = t.find("选项 4").unwrap()
      t.drag(x + 5.0, y + 5.0, x + 5.0, y - 70.0)
      t.draw()
      assert_eq(
        (scroll.at(view_tree().unwrap()) > scrolled, t.ime().0),
        (true, false),
        msg="\{case}: the field in the layer",
      )
    }
  }
}

///|
test "scroll_bar on padded scroll nodes: thumb hugs padding box edge, bar_near matches, drag reaches most" {
  let v_scroll = @view.Scroll::plain()
  let h_scroll = @view.Scroll::across()
  let t = Tester::new(fn(_c) {  }, w=400.0, h=400.0, platform=0)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(v) {
      v
      .width(Is(Some(300.0)))
      .height(Is(Some(180.0)))
      .padding(Is((8.0, 4.0, 8.0, 12.0)))
      .scrolls(v_scroll, bar=tree_scroll_bar(), fn(held) {
        for _ in 0..<10 {
          held.box(fn(r) { r.width(Is(Some(280.0))).height(Is(Some(40.0))) |> ignore }) |> ignore
        }
      })
      |> ignore
    })
    |> ignore
    root.box(fn(h) {
      h
      .width(Is(Some(300.0)))
      .height(Is(Some(120.0)))
      .padding(Is((8.0, 4.0, 8.0, 12.0)))
      .scrolls(h_scroll, bar=tree_scroll_bar(), fn(held) {
        held.row(Is(true)) |> ignore
        for _ in 0..<10 {
          held.box(fn(r) { r.width(Is(Some(80.0))).height(Is(Some(80.0))) |> ignore }) |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  // Vertical: pointer near right edge of padding box (x = 300 - scroll_bar_near + 1) wakes bar
  t.move_to(300.0 - scroll_bar_near + 1.0, 90.0)
  t.run_for(turn_done_ms)
  let v_thumbs = t
    .drawn_order()
    .filter(fn(d) { d.0 == 0 && d.3 == scroll_bar_size && d.2 < 180.0 && d.5 > 0.0 })
  assert_eq(v_thumbs.length(), 1, msg="vertical thumb count: \{Repr(v_thumbs)}")
  let vt = v_thumbs[0]
  let v_right = vt.1 + vt.3
  assert_true(
    (v_right - (300.0 - scroll_bar_inset)).abs() <= 0.01,
    msg="vertical thumb right=\{v_right} expected=\{300.0 - scroll_bar_inset}",
  )
  // Drag vertical thumb to the bottom: reaches most()
  t.drag(vt.1 + vt.3 / 2.0, vt.2 + vt.4 / 2.0, vt.1 + vt.3 / 2.0, 260.0)
  t.draw()
  assert_true(
    (v_scroll.at(view_tree().unwrap()) - v_scroll.most()).abs() <= 0.5,
    msg="vertical drag to end: at=\{v_scroll.at(view_tree().unwrap())} most=\{v_scroll.most()}",
  )
  // Horizontal: box is y=[180, 300], pointer near bottom edge wakes bar
  t.move_to(150.0, 300.0 - scroll_bar_near + 1.0)
  t.run_for(turn_done_ms)
  let h_thumbs = t
    .drawn_order()
    .filter(fn(d) { d.0 == 0 && d.4 == scroll_bar_size && d.2 >= 180.0 && d.5 > 0.0 })
  assert_eq(h_thumbs.length(), 1, msg="horizontal thumb count: \{Repr(h_thumbs)}")
  let ht = h_thumbs[0]
  let h_bottom = ht.2 + ht.4
  assert_true(
    (h_bottom - (300.0 - scroll_bar_inset)).abs() <= 0.01,
    msg="horizontal thumb bottom=\{h_bottom} expected=\{300.0 - scroll_bar_inset}",
  )
  // Drag horizontal thumb to the right end: reaches most()
  t.drag(ht.1 + ht.3 / 2.0, ht.2 + ht.4 / 2.0, 380.0, ht.2 + ht.4 / 2.0)
  t.draw()
  assert_true(
    (h_scroll.at(view_tree().unwrap()) - h_scroll.most()).abs() <= 0.5,
    msg="horizontal drag to end: at=\{h_scroll.at(view_tree().unwrap())} most=\{h_scroll.most()}",
  )
}

///|
/// A column 300 high of 40 rows 40 high, each pressed as it is tapped (a finger's: Android's): its scroll and how many
/// times a row was pressed.
fn pressed_rows_case() -> (Tester, @view.Scroll, Ref[Int]) {
  let s = @view.Scroll::new()
  let pressed = Ref(0)
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=2)
  set_view_app(fn(root) {
    root
    .width(Is(Some(400.0)))
    .height(Is(Some(300.0)))
    .scrolls(s, slop=touch_slop(), fn(held) {
      for i in 0..<40 {
        held.box(fn(r) {
          r
          .width(Is(Some(400.0)))
          .height(Is(Some(40.0)))
          .on_press(fn() { pressed.val += 1 })
          .says(Is(Some(@view.said(Button, label="第\{i}行"))))
          .words(Is("第\{i}行"))
          |> ignore
        })
        |> ignore
      }
    })
    |> ignore
  })
  t.draw()
  (t, s, pressed)
}

///|
test "a column of the tree's that scrolls, flung: a tap on a row in it as it glides on stops it there and presses nothing; at rest, the same tap presses the row" {
  let (t, s, pressed) = pressed_rows_case()
  let at = fn() { s.at(view_tree().unwrap()) }
  t.touch(0, 80.0, 250.0)
  for i in 1..=3 {
    t.run_for(hand_step_ms)
    t.touch(1, 80.0, 250.0 - 30.0 * i.to_double())
  }
  t.run_for(hand_half_step_ms)
  t.touch(2, 80.0, 145.0)
  t.run_for(hand_step_ms)
  assert_true(s.glides_till() is Some(end) && end > t.time(), msg="not gliding after the fling")
  // (tapped as it glides: caught where it is, no row pressed)
  t.tap(80.0, 150.0)
  let caught = at()
  t.run_for(bar_long_gone_ms)
  assert_eq((pressed.val, s.glides_till(), at()), (0, None, caught))
  // (at rest: the same tap presses the row under it)
  t.tap(80.0, 150.0)
  assert_eq(pressed.val, 1)
}

///|
/// A column the window's whole (400 by 300) of 40 rows 40 high, on a finger's host (Android's): each row nothing of its
/// own (`rows` 0), pressed as it is tapped (1), or a gesture counting its taps and its drags' ends (2); `list`: a page's
/// list's scroll. Its scroll and how many times a row was pressed, tapped or dragged.
fn two_finger_rows(rows : Int, list? : Bool = false) -> (Tester, @view.Scroll, Ref[Int]) {
  let s = if list { @view.Scroll::list() } else { @view.Scroll::new() }
  let pressed = Ref(0)
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=2)
  set_view_app(fn(root) {
    root
    .width(Is(Some(400.0)))
    .height(Is(Some(300.0)))
    .scrolls(s, slop=touch_slop(), fn(held) {
      for i in 0..<40 {
        held.box(fn(r) {
          r.width(Is(Some(400.0))).height(Is(Some(40.0))).words(Is("第\{i}行")) |> ignore
          if rows == 1 {
            r.on_press(fn() { pressed.val += 1 }).says(Is(Some(@view.said(Button, label="第\{i}行")))) |> ignore
          } else if rows == 2 {
            r
            .gesture(touch_slop(), tap=fn(_) { pressed.val += 1 }, drag=fn(d) { if d.kind == Up { pressed.val += 1 } })
            .says(Is(Some(@view.said(Button, label="第\{i}行"))))
            |> ignore
          }
        })
        |> ignore
      }
    })
    |> ignore
  })
  t.draw()
  (t, s, pressed)
}

///|
/// The host's fingers on it (`phase`: 0 down, 1 moved, 2 up, 3 called off; the system's id; y, all at x 200), each
/// `step` after the one before, and where the column stands after each.
fn two_fingers_on(
  t : Tester,
  s : @view.Scroll,
  events : Array[(Int, Int, Double)],
  step? : Double = hand_step_ms,
) -> Array[Double] {
  let stands = []
  for e in events {
    t.run_for(step)
    t.touch_raw(e.0, e.1, 200.0, e.2, t.time())
    stands.push(s.at(view_tree().unwrap()))
  }
  stands
}

///|
/// The host's finger `id` let go at y (x 200) a frame's step on, and what it sets going run to its end.
fn two_lift(t : Tester, id : Int, y : Double) -> Unit {
  t.run_for(hand_step_ms)
  t.touch_raw(2, id, 200.0, y, t.time())
  t.run_for(turn_done_ms)
}

///|
test "a column of the tree's that scrolls, a finger's (Android's): two fingers taking turns, round after round: the last down leads it, the other's moves move nothing; either let go, the other goes on from where it is, no jump; let go last, flung" {
  let (t, s, _) = two_finger_rows(0)
  let stands = two_fingers_on(t, s, [
    (0, 7, 250.0),
    (1, 7, 230.0),
    (1, 7, 210.0),
    // (the second down: it leads)
    (0, 9, 100.0),
    (1, 7, 190.0),
    (1, 9, 80.0),
    // (the first let go: the second goes on)
    (2, 7, 190.0),
    (1, 9, 70.0),
    // (the first down again: it leads)
    (0, 7, 250.0),
    (1, 7, 230.0),
    (1, 9, 40.0),
    // (the second let go: the first goes on)
    (2, 9, 40.0),
    (1, 7, 220.0),
    (1, 7, 200.0),
  ])
  // (let go a frame on as it goes)
  t.run_for(hand_step_ms)
  t.touch_raw(2, 7, 200.0, 200.0, t.time())
  let up = s.at(view_tree().unwrap())
  t.run_for(turn_done_ms)
  assert_eq(stands, [0.0, 12.0, 32.0, 32.0, 32.0, 52.0, 52.0, 62.0, 62.0, 82.0, 82.0, 82.0, 92.0, 112.0])
  assert_true(s.at(view_tree().unwrap()) > up, msg="not flung on from \{up}")
}

///|
test "a column of the tree's that scrolls, a finger's (Android's): a finger down on a row that is pressed or is a gesture, a second down before the first moved past the slop: either finger moving takes it to scroll, the first let go before or after, no jump, nothing pressed" {
  for rows in [1, 2] {
    // (the first let go first: the second sets it going from where it is)
    let (t, s, pressed) = two_finger_rows(rows)
    let first_up = two_fingers_on(t, s, [(0, 7, 100.0), (0, 9, 250.0), (2, 7, 100.0), (1, 9, 240.0), (1, 9, 220.0)])
    two_lift(t, 9, 220.0)
    assert_eq((first_up, pressed.val), ([0.0, 0.0, 0.0, 2.0, 22.0], 0), msg="rows \{rows}")
    // (the first held: the second moving takes it; the first let go after, the second goes on)
    let (t, s, pressed) = two_finger_rows(rows)
    let second = two_fingers_on(t, s, [
      (0, 7, 100.0),
      (0, 9, 250.0),
      (1, 9, 240.0),
      (1, 9, 220.0),
      (2, 7, 100.0),
      (1, 9, 210.0),
    ])
    two_lift(t, 9, 210.0)
    assert_eq((second, pressed.val), ([0.0, 0.0, 2.0, 22.0, 22.0, 32.0], 0), msg="rows \{rows}")
    // (the first moving takes it, the second there; the first let go, the second goes on from where it is)
    let (t, s, pressed) = two_finger_rows(rows)
    let first = two_fingers_on(t, s, [
      (0, 7, 100.0),
      (0, 9, 250.0),
      (1, 7, 80.0),
      (1, 7, 70.0),
      (2, 7, 70.0),
      (1, 9, 240.0),
    ])
    two_lift(t, 9, 240.0)
    assert_eq((first, pressed.val), ([0.0, 0.0, 12.0, 22.0, 22.0, 32.0], 0), msg="rows \{rows}")
  }
}

///|
test "a column of the tree's that scrolls, a finger's (Android's): the second finger leading let go, the first goes on from where it is; let go at once without moving instead, not flung by how it went before" {
  let (t, s, _) = two_finger_rows(0)
  let on = two_fingers_on(t, s, [(0, 7, 250.0), (1, 7, 230.0), (1, 7, 210.0), (0, 9, 100.0), (1, 9, 90.0), (2, 9, 90.0), (1, 7, 200.0), (1, 7, 190.0)], step=hand_half_step_ms)
  assert_eq(on, [0.0, 12.0, 32.0, 32.0, 42.0, 42.0, 52.0, 62.0])
  let (t, s, _) = two_finger_rows(0)
  let still = two_fingers_on(t, s, [(0, 7, 250.0), (1, 7, 230.0), (1, 7, 210.0), (0, 9, 100.0), (1, 9, 90.0), (2, 9, 90.0), (2, 7, 210.0)], step=hand_half_step_ms)
  t.run_for(turn_done_ms)
  assert_eq((still, s.at(view_tree().unwrap()), s.glides_till()), ([0.0, 12.0, 32.0, 32.0, 42.0, 42.0, 42.0], 42.0, None))
}

///|
test "a page's list, a finger's (Android's): pulled past its top by two fingers by turns, the system calling both off: stretched by both, then back to its top, once" {
  let (t, s, _) = two_finger_rows(0, list=true)
  let tree = view_tree().unwrap()
  let past = []
  for e in [(0, 7, 100.0), (1, 7, 130.0), (1, 7, 160.0), (0, 9, 150.0), (1, 9, 180.0), (1, 9, 210.0)] {
    t.run_for(hand_step_ms)
    t.touch_raw(e.0, e.1, 200.0, e.2, t.time())
    past.push(s.past(tree))
  }
  t.run_for(hand_step_ms)
  t.touch_raw(3, 7, 200.0, 160.0, t.time())
  let off = (s.past(tree), s.in_hand(), s.glides_till() is Some(_))
  t.run_for(bar_long_gone_ms)
  assert_true(past[2] > past[1] && past[4] > past[3] && past[5] > past[4], msg="\{past[1]} \{past[2]} \{past[3]} \{past[4]} \{past[5]}")
  assert_eq((off.0 == past[5], off.1, off.2), (true, false, true), msg="\{off.0} \{past[5]}")
  assert_eq((s.past(tree), s.glides_till(), s.at(tree)), (0.0, None, 0.0))
}
