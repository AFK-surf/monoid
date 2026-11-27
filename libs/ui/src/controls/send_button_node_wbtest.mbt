// The composer's send as a node (send_button_node): pressed only while it can go, read out so; its ground the old
// send's at rest each way and eased from one to the other from the moment it changed; a ring turning in place of its
// arrow while a new chat is made.

///|
/// A window holding one send, as `ready` and `starting` say, its presses counted in `pressed`.
fn send_tester(
  ready : @signals.Signal[Bool],
  starting : @signals.Signal[Bool],
  pressed : Ref[Int],
  icon_now? : () -> String = fn() { "arrow-up" },
) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=200.0, h=160.0, platform=0)
  set_dark(Some(false))
  @ui.set_tree_theme(ui_theme_now)
  @ui.set_view_app(fn(root) {
    root.box(fn(page) {
      page.pad(Is(24.0)).lines_up(Is(Some(Start))) |> ignore
      send_button_node(page, fn() { "发送" }, fn() { ready.get() }, fn() { starting.get() }, fn() { pressed.val += 1 }, icon_now~) |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// The icon drawn in the button's own bounds.
fn send_drawn_icon(t : @ui.Tester) -> String {
  guard t.query(Button, label="发送") is Some(button) && @ui.view_tree() is Some(tree) else { return "" }
  let (x, y, w, h) = button.rect
  for d in tree.drawn() {
    let name = tree.drawn_name(d.id)
    if name.has_prefix("/icon/") && d.x >= x && d.y >= y && d.x + d.w <= x + w && d.y + d.h <= y + h {
      return name
    }
  }
  ""
}

///|
test "send: a changed icon follows its action without drawing its accessible name" {
  let icon = @signals.signal("plus")
  let t = send_tester(@signals.signal(true), @signals.signal(false), Ref(0), icon_now=fn() { icon.get() })
  assert_eq(send_drawn_icon(t), "/icon/plus/")
  assert_false(t.words().iter().any(fn(w) { w.0 == "发送" }))
  icon.set("arrow-up")
  t.draw()
  assert_eq(send_drawn_icon(t), "/icon/arrow-up/")
  assert_true(t.query(Button, label="发送") is Some(_))
  assert_eq(t.audit(), [])
}

///|
/// The send's ground as drawn now.
fn send_drawn_ground(t : @ui.Tester) -> Int64 raise {
  let fills = t.drawn_rects().filter(fn(r) { (r.4 & 0xFFL) != 0L })
  guard fills is [.., last] else { fail("no ground drawn") }
  last.4
}

///|
test "send: pressed only while it can go, read out disabled while not" {
  let ready = @signals.signal(false, same=fn(a, b) { a == b })
  let starting = @signals.signal(false, same=fn(a, b) { a == b })
  let pressed = Ref(0)
  let t = send_tester(ready, starting, pressed)
  t.try_click(Button, label="发送") |> ignore
  t.draw()
  assert_eq(pressed.val, 0)
  assert_true(t.semantics().iter().any(fn(s) { s.role == @ui.Role::Button && s.disabled }))
  ready.set(true)
  t.run_for(dur_ms + 30.0)
  t.click(Button, label="发送")
  t.draw()
  assert_eq(pressed.val, 1)
}

///|
test "send: its ground the old send's at rest each way, eased from one to the other from the moment it changed" {
  let ready = @signals.signal(false, same=fn(a, b) { a == b })
  let starting = @signals.signal(false, same=fn(a, b) { a == b })
  let t = send_tester(ready, starting, Ref(0))
  let off = send_drawn_ground(t)
  assert_eq(off, send_ground(0.0, 0.0))
  ready.set(true)
  t.run_for(dur_ms / 2.0)
  let half = send_drawn_ground(t)
  assert_true(half != off && half != send_ground(1.0, 0.0), msg="half way: \{half}")
  t.run_for(dur_ms)
  assert_eq(send_drawn_ground(t), send_ground(1.0, 0.0))
}

///|
/// What is drawn in the middle of the send, traced to where it was made (Tester::sources_at).
fn send_middle_made(t : @ui.Tester) -> String raise {
  guard t.semantics().iter().find_first(fn(s) { s.role == @ui.Role::Button }) is Some(b) else { fail("no send") }
  let (x, y, w, h) = b.rect
  t.sources_at(x + w / 2.0, y + h / 2.0)
}

///|
test "send: a ring turning in place of its arrow while a new chat is made, the arrow back after" {
  let ready = @signals.signal(true, same=fn(a, b) { a == b })
  let starting = @signals.signal(false, same=fn(a, b) { a == b })
  let t = send_tester(ready, starting, Ref(0))
  assert_true(send_middle_made(t).contains("ui/src/controls/tool_node.mbt"), msg="no arrow: \{send_middle_made(t)}")
  starting.set(true)
  t.draw()
  assert_true(send_middle_made(t).contains("ui/src/controls/waiting.mbt"), msg="no ring: \{send_middle_made(t)}")
  starting.set(false)
  t.draw()
  assert_true(send_middle_made(t).contains("ui/src/controls/tool_node.mbt"), msg="the arrow not back: \{send_middle_made(t)}")
}
