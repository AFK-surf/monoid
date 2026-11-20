// The library's words and blocks pressed (text_action_node.mbt): each read out as what it is (a button, one chosen of
// several, one open or shut, a toggle), pressed once a press, taking none while disabled; a block pressed only while
// it has somewhere to go, read out as nothing to press else.

///|
test "words pressed: a button by their words, pressed once; disabled, none" {
  let pressed = Ref(0)
  let t = u5_case(fn(root) {
    // (each in a room of its own: a press's least reaches 44 round what is pressed)
    root.box(fn(b) {
      b.height(Is(Some(60.0))) |> ignore
      text_action_node(b, fn() { "显示全部 12 个" }, fn() { pressed.val += 1 }) |> ignore
    })
    |> ignore
    root.box(fn(b) {
      b.height(Is(Some(60.0))) |> ignore
      text_action_node(b, fn() { "换一个" }, fn() { pressed.val += 10 }, disabled=fn() { true }) |> ignore
    })
    |> ignore
  })
  t.click(Button, label="显示全部 12 个")
  t.draw()
  assert_eq(t.get(Button, label="换一个").disabled, true)
  t.click(Button, label="换一个")
  t.draw()
  assert_eq(pressed.val, 1)
}

///|
test "blocks pressed: chosen read out selected, open read out expanded, a toggle pressed" {
  let picked = @signals.signal("a")
  let open = @signals.signal(false)
  let on = @signals.signal(false)
  let t = u5_case(fn(root) {
    for k in ["a", "b"] {
      action_box_node(root, fn() { k }, selected=fn() { picked.get() == k }, fn(_) { picked.set(k) }, fn(b) {
        words_node(b, fn() { k }, fn() { u5_words }) |> ignore
      })
      |> ignore
    }
    action_box_node(root, fn() { "权限" }, expanded=fn() { open.get() }, fn(_) { open.set(!open.get()) }, fn(b) {
      words_node(b, fn() { "权限" }, fn() { u5_words }) |> ignore
    })
    |> ignore
    action_box_node(root, fn() { "全屏" }, on=fn() { on.get() }, fn(_) { on.set(!on.get()) }, fn(b) {
      words_node(b, fn() { "全屏" }, fn() { u5_words }) |> ignore
    })
    |> ignore
  })
  t.click(Button, label="b")
  t.click(Button, label="权限")
  t.click(Button, label="全屏")
  t.draw()
  assert_eq(t.all(Button, selected=true).map(fn(s) { s.label }), ["b"])
  assert_eq(t.all(Button, expanded=true).map(fn(s) { s.label }), ["权限"])
  assert_eq(t.get(Button, label="全屏").pressed, Some(true))
}

///|
test "a block pressed only while it goes somewhere: a button then, else nothing to press" {
  let goes = @signals.signal(true)
  let went = Ref(0)
  let t = u5_case(fn(root) {
    action_box_while_node(root, fn() { goes.get() }, fn() { "下一步" }, fn(_) { went.val += 1 }, fn(b) {
      words_node(b, fn() { "下一步" }, fn() { u5_words }) |> ignore
    })
  })
  t.click(Button, label="下一步")
  t.draw()
  goes.set(false)
  t.draw()
  assert_eq((went.val, t.all(Button, label="下一步").length()), (1, 0))
}

///|
test "a block pressed whose name never changes (label_is): a button by it, pressed once by a tap, once by Enter as Tab comes to it" {
  let pressed = Ref(0)
  let t = u5_case(fn(root) {
    action_box_node(root, fn() { "Claude · Studio" }, label_is="Claude · Studio", fn(_) { pressed.val += 1 }, fn(b) {
      words_node(b, fn() { "Claude" }, fn() { u5_words }) |> ignore
    })
    |> ignore
  })
  let s = t.get(Button, label="Claude · Studio")
  t.click(Button, label="Claude · Studio")
  t.draw()
  t.act(Button, Focus, label="别处")
  t.tab()
  t.draw()
  let at = match t.focused() {
    Some(f) => f.label
    None => ""
  }
  t.enter()
  t.draw()
  assert_eq((s.actions.contains(Activate), at, pressed.val), (true, "Claude · Studio", 2))
}

///|
test "a block pressed only while it goes somewhere, in its pick's own node (in_pick): a button then, pressed once, the same node as the plain box it is else; nothing to press else" {
  let goes = @signals.signal(true)
  let went = Ref(0)
  let t = u5_case(fn(root) {
    action_box_while_node(root, fn() { goes.get() }, fn() { "下一步" }, fn(_) { went.val += 1 }, in_pick=true, fn(b) {
      words_node(b, fn() { "下一步" }, fn() { u5_words }) |> ignore
    })
  })
  t.click(Button, label="下一步")
  t.draw()
  goes.set(false)
  t.draw()
  assert_eq((went.val, t.all(Button, label="下一步").length(), t.find("下一步") is Some(_)), (1, 0, true))
}
