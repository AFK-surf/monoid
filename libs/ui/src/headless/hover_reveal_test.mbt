// What shows on hover (@headless.hover_reveal), under a look of the tests' own: a row "行" 300 by 40 that does something
// pressed, its action "删除" (a button 60 by 30) faded out by its look while it does not show, a box "前" before it and
// "后" after it that take the focus. Not shown, the action is not pressed by a finger or the pointer (the press lands on
// the row) and Tab still comes to it, showing it; the pointer over the row shows it and presses it; `always` shows it
// to a finger. An action that is a box of two buttons turns both away from the hand and shows for the focus on either.
// Each window is made by `window` (window_test.mbt), which holds that hover_reveal.mbt draws and lays out nothing.

///|
/// What a case keeps: its window, the presses the row and each action took, its caller's `always`, and what its look
/// read.
struct RevealCase {
  t : @ui.Tester
  rows : Ref[Int]
  acts : Map[String, Int]
  always : @signals.Signal[Bool]
  reveal : Ref[@headless.HoverReveal?]
}

///|
/// A box called `name`, 60 by 30, that takes the focus and does nothing pressed.
fn stop(parent : @view.View, name : String) -> Unit {
  parent.box(fn(e) {
    e
    .width(Is(Some(60.0)))
    .height(Is(Some(30.0)))
    .presses(Is(true))
    .focusable(Is(true))
    .says(Is(Some(@view.said(Button, label=name))))
    .on_press(fn() {  })
    |> ignore
  })
  |> ignore
}

///|
/// A window pointed at with `pointing`: "前", the row "行" (pressed, counted in `rows`) holding its actions, and "后".
/// The actions are the button "删除" alone, or (`box_of`) a box holding "复制" and "删除", each counted in `acts` as
/// pressed; shown by `hover_reveal` (with `always`), the look fading the action out while it does not show. `outside`:
/// the box of two is not in the row but under it, beside it in the window (as one in a layer is).
fn reveal_case(
  pointing? : @ui.Pointing = Mouse,
  box_of? : Bool = false,
  outside? : Bool = false,
) -> RevealCase raise {
  let rows = Ref(0)
  let acts : Map[String, Int] = Map([])
  let always = @signals.signal(false, same=fn(a : Bool, b : Bool) { a == b })
  let reveal : Ref[@headless.HoverReveal?] = Ref(None)
  let act = fn(parent : @view.View, name : String) {
    @headless.button(parent, fn() { name }, fn(_) { acts[name] = acts.get(name).unwrap_or(0) + 1 }, fn(v, _) {
      v.width(Is(Some(60.0))).height(Is(Some(30.0))) |> ignore
    })
  }
  let two = fn(parent : @view.View, held : Array[@view.View]) {
    parent.box(fn(b) {
      b.row(Is(true)) |> ignore
      held.push(act(b, "复制"))
      held.push(act(b, "删除"))
    })
  }
  // (the look: the action faded out while it does not show)
  let look = fn(action : @view.View, r : @headless.HoverReveal) {
    action.alpha(By(fn() { if r.shown() { 1.0 } else { 0.0 } })) |> ignore
    reveal.val = Some(r)
  }
  let t = window(pointing~, fn(root) {
    stop(root, "前")
    let row_node = root.box(fn(row) {
      row
      .width(Is(Some(300.0)))
      .height(Is(Some(40.0)))
      .row(Is(true))
      .presses(Is(true))
      .says(Is(Some(@view.said(Button, label="行"))))
      .on_press(fn() { rows.val += 1 })
      |> ignore
      if outside {
        ()
      } else if box_of {
        let held = []
        let acts_box = two(row, held)
        look(acts_box, @headless.hover_reveal(row, acts_box, also=held, always=fn() { always.get() }))
      } else {
        let b = act(row, "删除")
        look(b, @headless.hover_reveal(row, b, always=fn() { always.get() }))
      }
    })
    if outside {
      let held = []
      let acts_box = two(root, held)
      look(acts_box, @headless.hover_reveal(row_node, acts_box, also=held, always=fn() { always.get() }))
    }
    stop(root, "后")
  })
  { t, rows, acts, always, reveal }
}

///|
/// Whether the action shows now, as its look reads it.
fn RevealCase::shown(self : RevealCase) -> Bool {
  self.reveal.val.unwrap().shown()
}

///|
/// The middle of what is called `name`.
fn RevealCase::middle(self : RevealCase, name : String) -> (Double, Double) {
  let (x, y, w, h) = self.t.get(Button, label=name).rect
  (x + w / 2.0, y + h / 2.0)
}

///|
/// Who has the keyboard's focus, by name ("": nobody that says a name).
fn RevealCase::focus(self : RevealCase) -> String {
  match self.t.focused() {
    Some(s) => s.label
    None => ""
  }
}

///|
/// How many times the action called `name` was pressed.
fn RevealCase::pressed(self : RevealCase, name : String) -> Int {
  self.acts.get(name).unwrap_or(0)
}

///|
test "not shown, a finger's tap where the action is lands on the row: the action is not pressed" {
  let k = reveal_case(pointing=Finger)
  let before = k.shown()
  let (x, y) = k.middle("删除")
  k.t.tap(x, y)
  assert_eq((before, k.shown(), k.pressed("删除"), k.rows.val), (false, false, 0, 1))
}

///|
test "the first Tab from before the row comes to the action and shows it; Enter and Space press it; Tab on hides it" {
  let k = reveal_case()
  k.t.move_to(390.0, 290.0)
  k.t.tab()
  let first = (k.focus(), k.shown())
  k.t.tab()
  let on = (k.focus(), k.shown())
  k.t.key(@ui.key_code_enter)
  k.t.key(@ui.key_space)
  let pressed = k.pressed("删除")
  k.t.tab()
  assert_eq(
    (first, on, pressed, k.focus(), k.shown(), k.rows.val),
    (("前", false), ("删除", true), 2, "后", false, 0),
  )
}

///|
test "the pointer over the row shows the action and a click presses it; gone off the row, hidden" {
  let k = reveal_case()
  k.t.move_to(390.0, 290.0)
  let away = k.shown()
  let (rx, ry, _, rh) = k.t.get(Button, label="行").rect
  k.t.move_to(rx + 250.0, ry + rh / 2.0)
  let over = k.shown()
  let (x, y) = k.middle("删除")
  k.t.move_to(x, y)
  let on_it = k.shown()
  k.t.tap(x, y)
  let pressed = (k.pressed("删除"), k.rows.val)
  k.t.move_to(390.0, 290.0)
  assert_eq((away, over, on_it, pressed, k.shown()), (false, true, true, (1, 0), false))
}

///|
test "the pointer come straight onto the action from outside the row: shown, and a click presses the action" {
  let k = reveal_case()
  k.t.move_to(390.0, 290.0)
  let (x, y) = k.middle("删除")
  k.t.move_to(x, y)
  let shown = k.shown()
  k.t.tap(x, y)
  assert_eq((shown, k.pressed("删除"), k.rows.val), (true, 1, 0))
}

///|
test "always (a finger, where no hover comes): shown, and a tap presses the action; always off again, hidden" {
  let k = reveal_case(pointing=Finger)
  k.always.set(true)
  k.t.draw()
  let shown = k.shown()
  let (x, y) = k.middle("删除")
  k.t.tap(x, y)
  let pressed = (k.pressed("删除"), k.rows.val)
  k.always.set(false)
  k.t.draw()
  let hidden = k.shown()
  k.t.tap(x, y)
  assert_eq((shown, pressed, hidden, k.pressed("删除"), k.rows.val), (true, (1, 0), false, 1, 1))
}

///|
test "a box of two actions: not shown, a finger's tap on either lands on the row; Tab comes to each, showing them" {
  let k = reveal_case(pointing=Finger, box_of=true)
  let (cx, cy) = k.middle("复制")
  let (dx, dy) = k.middle("删除")
  k.t.tap(cx, cy)
  k.t.tap(dx, dy)
  let tapped = (k.pressed("复制"), k.pressed("删除"), k.rows.val)
  k.t.tab()
  k.t.tab()
  let copy = (k.focus(), k.shown())
  k.t.tab()
  let delete = (k.focus(), k.shown())
  k.t.key(@ui.key_code_enter)
  k.t.tab()
  assert_eq(
    (tapped, copy, delete, k.pressed("删除"), k.focus(), k.shown()),
    ((0, 0, 2), ("复制", true), ("删除", true), 1, "后", false),
  )
}

///|
test "a box of two actions under the pointer: over the row shown, and a click on either presses it" {
  let k = reveal_case(box_of=true)
  let (cx, cy) = k.middle("复制")
  let (dx, dy) = k.middle("删除")
  k.t.move_to(cx, cy)
  let shown = k.shown()
  k.t.tap(cx, cy)
  k.t.move_to(dx, dy)
  k.t.tap(dx, dy)
  assert_eq((shown, k.pressed("复制"), k.pressed("删除"), k.rows.val), (true, 1, 1, 0))
}

///|
test "a box of two actions outside the row: over the row shown; gone on from the row onto a button in it, still shown, and a click presses it" {
  let k = reveal_case(outside=true)
  k.t.move_to(390.0, 290.0)
  let away = k.shown()
  let (rx, ry, _, rh) = k.t.get(Button, label="行").rect
  k.t.move_to(rx + 250.0, ry + rh / 2.0)
  let over = k.shown()
  let (cx, cy) = k.middle("复制")
  k.t.move_to(cx, cy)
  let on_it = k.shown()
  k.t.tap(cx, cy)
  let pressed = (k.pressed("复制"), k.rows.val)
  k.t.move_to(390.0, 290.0)
  assert_eq((away, over, on_it, pressed, k.shown()), (false, true, true, (1, 0), false))
}
