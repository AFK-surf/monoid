// A control's states as one reading (@headless.ControlState) and what a look's property is in them
// (@headless.StateStyle): each state's order of winning, and each component's reading as the hand, the keys and its
// caller change it. Each window is made by `window` (window_test.mbt), which holds that state_set.mbt draws nothing.

///|
/// No state holding.
let ss_rest : @headless.ControlState = {
  hovered: false,
  pressed: false,
  focused: false,
  focus_shown: false,
  disabled: false,
  selected: false,
  open: false,
  busy: false,
}

///|
/// A style naming each state by its own word.
fn ss_all() -> @headless.StateStyle[String] {
  @headless.StateStyle::new(
    base="base",
    disabled="disabled",
    busy="busy",
    pressed="pressed",
    selected_hovered="selected_hovered",
    selected="selected",
    open="open",
    hovered="hovered",
    focused="focused",
  )
}

///|
test "each state wins over those after it: disabled, busy, pressed, selected and hovered, selected, open, hovered, the focus shown, base" {
  let s = ss_all()
  let all = { ..ss_rest, hovered: true, pressed: true, focus_shown: true, disabled: true, selected: true, open: true, busy: true }
  let got = [
    s.resolve(all),
    s.resolve({ ..all, disabled: false }),
    s.resolve({ ..all, disabled: false, busy: false }),
    s.resolve({ ..all, disabled: false, busy: false, pressed: false }),
    s.resolve({ ..all, disabled: false, busy: false, pressed: false, hovered: false }),
    s.resolve({ ..all, disabled: false, busy: false, pressed: false, selected: false }),
    s.resolve({ ..all, disabled: false, busy: false, pressed: false, selected: false, open: false }),
    s.resolve({ ..ss_rest, focus_shown: true }),
    // (focused without it shown, a pointer's press's: no ring's state)
    s.resolve({ ..ss_rest, focused: true }),
    s.resolve(ss_rest),
  ]
  assert_eq(got, [
    "disabled", "busy", "pressed", "selected_hovered", "selected", "open", "hovered", "focused", "base", "base",
  ])
}

///|
test "a state said nowhere falls to the next that is: selected and hovered without its own is selected, pressed without its own hovered" {
  let s = @headless.StateStyle::new(base=0, selected=2, hovered=1)
  assert_eq(
    (
      s.resolve({ ..ss_rest, selected: true, hovered: true }),
      s.resolve({ ..ss_rest, pressed: true, hovered: true }),
      s.resolve({ ..ss_rest, disabled: true }),
    ),
    (2, 1, 0),
  )
}

///|
test "a button's state as the mouse rests on it and presses it, as the keys come to it, as it is disabled; selected and busy as its look says" {
  let off = @signals.signal(false)
  let read : Ref[@headless.Button?] = Ref(None)
  let t = window(fn(root) {
    @headless.button(root, fn() { "前" }, fn(_) {  }, fn(v, _) { v.width(Is(Some(80.0))).height(Is(Some(40.0))) |> ignore })
    |> ignore
    @headless.button(root, fn() { "钮" }, fn(_) {  }, disabled=fn() { off.get() }, fn(v, b) {
      read.val = Some(b)
      v.width(Is(Some(80.0))).height(Is(Some(40.0))) |> ignore
    })
    |> ignore
  })
  let b = read.val.unwrap()
  let (x, y, w, h) = t.get(Button, label="钮").rect
  let (cx, cy) = (x + w / 2.0, y + h / 2.0)
  let rest = b.state()
  t.move_to(cx, cy)
  let over = b.state()
  t.press_at(cx, cy)
  let held = b.state()
  t.release(cx, cy)
  t.move_to(300.0, 280.0)
  t.act(Button, Focus, label="前")
  t.tab()
  let keyed = b.state(selected=true, busy=true)
  off.set(true)
  t.draw()
  let disabled = b.state()
  assert_eq((rest, over.hovered, held.pressed, (keyed.focused, keyed.focus_shown, keyed.selected, keyed.busy), disabled), (
    ss_rest,
    true,
    true,
    (true, true, true, true),
    { ..ss_rest, disabled: true },
  ))
}

///|
test "a toggle selected while on, a choice while chosen, a disclosure open while what it opens is" {
  let on = @signals.signal(false)
  let tg : Ref[@headless.Toggle?] = Ref(None)
  let ch : Ref[@headless.Choice?] = Ref(None)
  let ds : Ref[@headless.Disclosure?] = Ref(None)
  let size = fn(v : @view.View) { v.width(Is(Some(80.0))).height(Is(Some(30.0))) |> ignore }
  let _ = window(fn(root) {
    @headless.toggle(root, Switch, fn() { "开关" }, fn() { on.get() }, fn(b) { on.set(b) }, fn(v, s) {
      tg.val = Some(s)
      size(v)
    })
    |> ignore
    @headless.choice(root, Radio, fn() { "选项" }, fn() { on.get() }, fn(_) {  }, fn(v, s) {
      ch.val = Some(s)
      size(v)
    })
    |> ignore
    @headless.disclosure(root, fn() { "展开" }, fn() { on.get() }, fn(_) {  }, fn(v, s) {
      ds.val = Some(s)
      size(v)
    })
    |> ignore
  })
  let read = fn() {
    (tg.val.unwrap().state().selected, ch.val.unwrap().state().selected, ds.val.unwrap().state(busy=true))
  }
  let before = read()
  on.set(true)
  let after = read()
  assert_eq((before, after), (
    (false, false, { ..ss_rest, busy: true }),
    (true, true, { ..ss_rest, open: true, busy: true }),
  ))
}
