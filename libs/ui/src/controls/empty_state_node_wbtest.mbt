// The library's empty state (empty_state_node.mbt): its icon, title, note and what to do in its middle, each under the
// one before; the note in lines no wider than empty_state_words' 320, whole at a phone's width; no note, nor its room,
// where it has none; no action where none is given; nothing the audit finds at 390 and 1280.

///|
/// A window `w` wide holding an empty state, its note `note` and a button "新建对话" as what to do where `action`.
fn empty2(note : String, action : Bool, w? : Double = 600.0) -> @ui.Tester {
  w2_case(w~, fn(root) {
    if action {
      empty_state_node(root, "chats", fn() { "还没有对话" }, note=fn() { note }, action=fn(a) {
        button_node(a, fn() { "新建对话" }, fn() {  }, tone=Primary) |> ignore
      })
      |> ignore
    } else {
      empty_state_node(root, "chats", fn() { "还没有对话" }, note=fn() { note }) |> ignore
    }
  })
}

///|
let empty2_long : String = "在任意一台机器上开始一个新对话后，它会出现在这里。你也可以从 Slack、飞书或者群聊里把对话交给这里的 agent。"

///|
test "empty state with a note and what to do, at 390 and 1280: its title, note and button each under the one before, in its middle; the note in lines 320 wide at most, whole; nothing the audit finds" {
  for w in [390.0, 1280.0] {
    let t = empty2(empty2_long, true, w~)
    let (tx, ty, tw, th) = t.rect_of("还没有对话").unwrap()
    let (nx, ny, nw, nh) = t.rect_of(empty2_long).unwrap()
    let b = t.get(Button, label="新建对话").rect
    let what = "\{w}: title \{tx} \{tw}, note \{nx} \{nw}, button \{b.0} \{b.2}"
    let middle = 16.0 + (w - 32.0) / 2.0
    assert_true(ty + th <= ny && ny + nh <= b.1, msg=what)
    assert_true((tx + tw / 2.0 - middle).abs() <= 1.0, msg=what)
    assert_true((nx + nw / 2.0 - middle).abs() <= 1.0, msg=what)
    assert_true((b.0 + b.2 / 2.0 - middle).abs() <= 1.0, msg=what)
    assert_true(nw <= 320.5, msg="\{what}: \{nw}")
    // (in lines, never one cut short)
    assert_true(nh > 30.0, msg="\{what}: \{nh}")
    assert_eq(t.audit(), [], msg=what)
  }
}

///|
test "empty state without a note or what to do: neither shown, its title the last of it; nothing the audit finds" {
  let bare = empty2("", false)
  let (_, ty, _, th) = bare.rect_of("还没有对话").unwrap()
  assert_eq(bare.all(Button, label="新建对话").length(), 0)
  assert_true(bare.rect_of("说明") is None)
  // (nothing drawn under its title: no note's room, no action's)
  assert_true(bare.drawn_rects().all(fn(r) { r.1 < ty + th }))
  assert_eq(bare.audit(), [])
}
