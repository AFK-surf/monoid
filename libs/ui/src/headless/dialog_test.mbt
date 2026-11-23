// The headless dialog (@headless.dialog), under a look of the tests' own: read out a Dialog (or an AlertDialog) by its
// name while open, modal (what is under it takes no press), the focus given to what it holds as it opens and back as it
// goes; Escape, back and a press outside it telling on_close, a press on its own ground not; and, from the cause that
// closes it, none of that while its way out is drawn: what is under it the hand's at once. Each window is made by
// `window` (window_test.mbt), which holds that dialog.mbt draws and lays out nothing.

///|
/// How long the tests' dialog takes to go (View::show's leave): long past every step a test takes while it goes.
let dialog_leave_ms : Double = 300.0

///|
/// What a case keeps: its window, whether it is open (the caller's), how many times on_close was told, the presses
/// of the buttons by name, and what its look read.
struct DialogCase {
  t : @ui.Tester
  open : @signals.Signal[Bool]
  closes : Ref[Int]
  pressed : Map[String, Int]
  state : Ref[@headless.Dialog?]
}

///|
/// A window: buttons "打开" (opens the dialog) and "别处" down its left, and the dialog "设置" while open: over what is
/// beside it, 200 right of where it is made and 20 down, 160 by 160, holding buttons "确定" and "取消" (each closing it by its caller, no on_close told), going
/// over `dialog_leave_ms`.
fn dialog_case(
  kind? : @headless.DialogKind = Dialog,
  modal? : Bool = true,
  outside? : Bool = true,
  escape? : Bool = true,
  back_to_other? : Bool = false,
) -> DialogCase raise {
  let open = @signals.signal(false)
  let closes = Ref(0)
  let pressed : Map[String, Int] = Map([])
  let state = Ref(None)
  let other : Ref[@view.View?] = Ref(None)
  let button = fn(parent : @view.View, name : String, then : () -> Unit) {
    @headless.button(
      parent,
      fn() { name },
      fn(_) {
        pressed[name] = pressed.get(name).unwrap_or(0) + 1
        then()
      },
      fn(v, _) { v.width(Is(Some(120.0))).height(Is(Some(40.0))) |> ignore },
    )
  }
  let t = window(fn(root) {
    button(root, "打开", fn() { open.set(true) }) |> ignore
    other.val = Some(button(root, "别处", fn() {  }))
    root.show(fn() { open.get() }, leave=dialog_leave_ms, fn(s) {
      @headless.dialog(
        s,
        fn() { "设置" },
        fn() { open.get() },
        fn() {
          closes.val += 1
          open.set(false)
        },
        kind~,
        modal~,
        close_on_outside=outside,
        close_on_escape=escape,
        return_focus?=if back_to_other { other.val } else { None },
        description=fn() { "改了就存" },
        fn(v, d) {
          state.val = Some(d)
          v
          .over(Is(true))
          .offset(Is((200.0, 20.0)))
          .width(Is(Some(160.0)))
          .height(Is(Some(160.0)))
          .ground(Is(c_rest))
          |> ignore
          button(v, "确定", fn() { open.set(false) }) |> ignore
          button(v, "取消", fn() { open.set(false) }) |> ignore
        },
      )
      |> ignore
    })
    |> ignore
  })
  { t, open, closes, pressed, state }
}

///|
/// The name of what has the focus ("none": nothing).
fn dialog_focus(t : @ui.Tester) -> String {
  t.focused().map(fn(s) { s.label }).unwrap_or("none")
}

///|
/// Whether "别处", under the dialog, is kept from what reads the screen (by a modal layer over it).
fn dialog_under_hidden(t : @ui.Tester) -> Bool {
  t.query(Button, label="别处").map(fn(s) { s.hidden }).unwrap_or(true)
}

///|
/// The middle of the button called `name`.
fn dialog_middle(t : @ui.Tester, name : String) -> (Double, Double) raise {
  let (x, y, w, h) = t.get(Button, label=name).rect
  (x + w / 2.0, y + h / 2.0)
}

///|
test "a dialog opened by the keys: read out a Dialog by its name and words, modal: what is under it not read out and taking no press, a press there closing it; the focus on its first button" {
  let k = dialog_case()
  k.t.set_a11y(true)
  let (ox, oy) = dialog_middle(k.t, "别处")
  k.t.act(Button, Focus, label="打开")
  k.t.enter()
  let d = k.t.get(Dialog, label="设置")
  let under_hidden = dialog_under_hidden(k.t)
  let inside = dialog_focus(k.t)
  // (a press on 别处 under it: none of its)
  k.t.tap(ox, oy)
  let under = k.pressed.get("别处").unwrap_or(0)
  let closed_by_tap = k.closes.val
  assert_eq((d.description, under_hidden, inside, under, closed_by_tap), ("改了就存", true, "确定", 0, 1))
}

///|
test "Escape with the focus in it tells on_close once; the focus back on what opened it at once; the dialog no longer read out" {
  let k = dialog_case(outside=false)
  k.t.act(Button, Focus, label="打开")
  k.t.enter()
  let inside = dialog_focus(k.t)
  k.t.key(@ui.key_escape)
  let at_once = (k.closes.val, k.open.get(), dialog_focus(k.t), k.t.query(Dialog, label="设置") is Some(_))
  // (Escape again, the dialog going: nothing more told)
  k.t.key(@ui.key_escape)
  k.t.run_for(dialog_leave_ms)
  assert_eq((inside, at_once, k.closes.val, dialog_focus(k.t)), ("确定", (1, false, "打开", false), 1, "打开"))
}

///|
test "from the cause that closes it, what is under it takes a press at once, while its way out is still drawn" {
  let k = dialog_case()
  let (ox, oy) = dialog_middle(k.t, "别处")
  k.t.click(Button, label="打开")
  k.t.click(Button, label="取消")
  // (going: 300 ms of its way out still ahead)
  k.t.run_for(dialog_leave_ms / 10.0)
  let going = k.state.val.unwrap().open()
  k.t.tap(ox, oy)
  assert_eq((going, k.pressed.get("取消"), k.pressed.get("别处"), k.closes.val), (false, Some(1), Some(1), 0))
}

///|
test "a press on its own ground is no press outside it; a press outside it tells on_close once, nothing under it pressed" {
  let k = dialog_case()
  let (ox, oy) = dialog_middle(k.t, "别处")
  k.t.click(Button, label="打开")
  // (its ground, 10 above its foot, under its two buttons)
  let (dx, dy, dw, dh) = k.t.get(Dialog, label="设置").rect
  k.t.tap(dx + dw / 2.0, dy + dh - 10.0)
  let on_ground = (k.closes.val, k.open.get())
  k.t.tap(ox, oy)
  assert_eq((on_ground, k.closes.val, k.open.get(), k.pressed.get("别处")), ((0, true), 1, false, None))
}

///|
test "an alert dialog that a press outside does not close, nor Escape: read out an AlertDialog; only its own buttons close it" {
  let k = dialog_case(kind=AlertDialog, outside=false, escape=false)
  let (ox, oy) = dialog_middle(k.t, "别处")
  k.t.click(Button, label="打开")
  let role = k.t.query(AlertDialog, label="设置") is Some(_)
  k.t.tap(ox, oy)
  k.t.key(@ui.key_escape)
  let still = (k.closes.val, k.open.get())
  k.t.click(Button, label="确定")
  assert_eq((role, still, k.open.get(), k.pressed.get("别处")), (true, (0, true), false, None))
}

///|
test "a dialog that is not modal: what is beside it takes presses while it is open; a press there closes it as it goes down" {
  let k = dialog_case(modal=false)
  let (ox, oy) = dialog_middle(k.t, "别处")
  k.t.click(Button, label="打开")
  let under_hidden = dialog_under_hidden(k.t)
  k.t.tap(ox, oy)
  assert_eq((under_hidden, k.pressed.get("别处"), k.closes.val, k.open.get()), (false, Some(1), 1, false))
}

///|
test "return_focus: closed, the focus goes to the node it names, not to what opened it" {
  let k = dialog_case(back_to_other=true)
  k.t.act(Button, Focus, label="打开")
  k.t.enter()
  k.t.key(@ui.key_escape)
  assert_eq((k.closes.val, dialog_focus(k.t)), (1, "别处"))
}

///|
test "nested Dialog + Popover on unified overlay stack: 1st Escape closes Popover alone, 2nd closes Dialog; clicking Dialog ground or outside both closes Popover alone" {
  let dlg_open = @signals.signal(false)
  let pop_open = @signals.signal(false)
  let dlg_closes = Ref(0)
  let pop = @headless.Popover::new(fn() { pop_open.get() }, fn(v) { pop_open.set(v) })
  let size = fn(v : @view.View) { v.width(Is(Some(100.0))).height(Is(Some(36.0))) |> ignore }
  let t = window(fn(root) {
    @headless.button(root, fn() { "打开弹窗" }, fn(_) { dlg_open.set(true) }, fn(v, _) { size(v) }) |> ignore
    root.show(fn() { dlg_open.get() }, leave=dialog_leave_ms, fn(s) {
      @headless.dialog(
        s,
        fn() { "外层弹窗" },
        fn() { dlg_open.get() },
        fn() {
          dlg_closes.val += 1
          dlg_open.set(false)
        },
        fn(v, _) {
          v
          .over(Is(true))
          .offset(Is((120.0, 20.0)))
          .width(Is(Some(240.0)))
          .height(Is(Some(220.0)))
          .ground(Is(c_rest))
          |> ignore
          pop.trigger(v, fn() { "内层筛选" }, fn(b, _) { size(b) }) |> ignore
        },
      )
      |> ignore
    })
    |> ignore
    // Mount Popover as a sibling layer on root (as Popover::layer does in apps)
    root.show(fn() { pop_open.get() }, leave=dialog_leave_ms, fn(ps) {
      pop.content(ps, fn() { "内层浮层" }, fn(pv) {
        pv
        .over(Is(true))
        .offset(Is((140.0, 80.0)))
        .width(Is(Some(140.0)))
        .height(Is(Some(80.0)))
        .ground(Is(c_rest))
        |> ignore
        @headless.button(pv, fn() { "浮层项" }, fn(_) {  }, fn(b, _) { size(b) }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  // Open Dialog, then open Popover
  t.click(Button, label="打开弹窗")
  t.click(Button, label="内层筛选")
  assert_eq((dlg_open.get(), pop_open.get()), (true, true))
  // 1st Escape closes Popover ONLY; Dialog stays open
  t.key(@ui.key_escape)
  let after_esc1 = (pop_open.get(), dlg_open.get(), dlg_closes.val)
  // 2nd Escape closes Dialog
  t.key(@ui.key_escape)
  let after_esc2 = (pop_open.get(), dlg_open.get(), dlg_closes.val)
  t.run_for(dialog_leave_ms)
  // Reopen both, then click on Dialog's own ground (outside Popover and its trigger) -> closes Popover ONLY
  t.click(Button, label="打开弹窗")
  t.click(Button, label="内层筛选")
  let (dx, dy, dw, dh) = t.get(Dialog, label="外层弹窗").rect
  t.tap(dx + dw - 10.0, dy + dh - 10.0)
  let after_ground = (pop_open.get(), dlg_open.get(), dlg_closes.val)
  t.run_for(dialog_leave_ms)
  // Reopen Popover, then click OUTSIDE BOTH Dialog and Popover -> closes Popover ONLY (no double-close!)
  t.click(Button, label="内层筛选")
  t.tap(10.0, 200.0)
  let after_outside = (pop_open.get(), dlg_open.get(), dlg_closes.val)
  assert_eq(
    (after_esc1, after_esc2, after_ground, after_outside),
    ((false, true, 0), (false, false, 1), (false, true, 1), (false, true, 1)),
  )
}
