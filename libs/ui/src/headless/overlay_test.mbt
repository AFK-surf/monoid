// The headless overlay stack (@headless.overlay), under a look of the tests' own: a modal dialog closed by Escape, back
// and a press outside it (none on its own ground or on what opened it), the focus given in as it opens and back as it
// goes; a menu opened on it closed first by each of those, the dialog after; an inert layer taking nothing and letting
// all through; a layer that takes no Escape (a toast's) letting it through; and none left in the stack once all are let
// go. Each window is made by `window` (window_test.mbt), which holds that overlay.mbt draws and lays out nothing.

///|
/// How long the tests' layers take to go (View::show's leave): long past every step a test takes while one goes.
let ov_leave_ms : Double = 200.0

///|
/// What a case keeps: its window, whether the dialog, its menu and the toast are open (the caller's), whether the menu
/// is inert, what each was told would close it, the presses of the buttons by name, and what the looks read.
struct OvCase {
  t : @ui.Tester
  dialog : @signals.Signal[Bool]
  menu : @signals.Signal[Bool]
  toast : @signals.Signal[Bool]
  menu_inert : @signals.Signal[Bool]
  dialog_told : Array[@headless.OverlayDismiss]
  menu_told : Array[@headless.OverlayDismiss]
  pressed : Map[String, Int]
  dialog_state : Ref[@headless.Overlay?]
  menu_state : Ref[@headless.Overlay?]
}

///|
/// A window: buttons "打开" (opens the dialog) and "别处" down its left; the toast's layer (no Escape, no press outside)
/// while it is open; the modal dialog "设置" while open, 200 right and 20 down, 160 by 200, holding "菜单" (opens the
/// menu) and "确定"; in it the menu "菜单项" while open, 100 down, 140 by 60, holding "复制". Each goes over
/// `ov_leave_ms`.
fn ov_case() -> OvCase raise {
  let dialog = @signals.signal(false)
  let menu = @signals.signal(false)
  let toast = @signals.signal(false)
  let menu_inert = @signals.signal(false)
  let dialog_told = []
  let menu_told = []
  let pressed : Map[String, Int] = Map([])
  let dialog_state = Ref(None)
  let menu_state = Ref(None)
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
    let opener = button(root, "打开", fn() { dialog.set(true) })
    button(root, "别处", fn() {  }) |> ignore
    root.show(fn() { toast.get() }, leave=ov_leave_ms, fn(s) {
      @headless.overlay(s, fn(_) {  }, dismiss_on_escape=false, dismiss_on_outside=false, fn(v, _) {
        v.over(Is(true)).width(Is(Some(100.0))).height(Is(Some(30.0))).ground(Is(c_rest)) |> ignore
      })
      |> ignore
    })
    |> ignore
    root.show(fn() { dialog.get() }, leave=ov_leave_ms, fn(s) {
      @headless.overlay(
        s,
        fn(how) {
          dialog_told.push(how)
          dialog.set(false)
        },
        modal=true,
        anchor=opener,
        label=fn() { "设置" },
        fn(v, o) {
          dialog_state.val = Some(o)
          v
          .over(Is(true))
          .offset(Is((200.0, 20.0)))
          .width(Is(Some(160.0)))
          .height(Is(Some(200.0)))
          .ground(Is(c_rest))
          |> ignore
          let trigger = button(v, "菜单", fn() { menu.set(true) })
          button(v, "确定", fn() {  }) |> ignore
          v.show(fn() { menu.get() }, leave=ov_leave_ms, fn(m) {
            @headless.overlay(
              m,
              fn(how) {
                menu_told.push(how)
                menu.set(false)
              },
              anchor=trigger,
              inert=fn() { menu_inert.get() },
              label=fn() { "菜单项" },
              fn(mv, mo) {
                menu_state.val = Some(mo)
                mv
                .over(Is(true))
                .offset(Is((0.0, 100.0)))
                .width(Is(Some(140.0)))
                .height(Is(Some(60.0)))
                .ground(Is(c_rest))
                |> ignore
                button(mv, "复制", fn() {  }) |> ignore
              },
            )
            |> ignore
          })
          |> ignore
        },
      )
      |> ignore
    })
    |> ignore
  })
  { t, dialog, menu, toast, menu_inert, dialog_told, menu_told, pressed, dialog_state, menu_state }
}

///|
/// The name of what has the focus ("none": nothing).
fn ov_focus(t : @ui.Tester) -> String {
  t.focused().map(fn(s) { s.label }).unwrap_or("none")
}

///|
/// The middle of the button called `name`.
fn ov_middle(t : @ui.Tester, name : String) -> (Double, Double) raise {
  let (x, y, w, h) = t.get(Button, label=name).rect
  (x + w / 2.0, y + h / 2.0)
}

///|
/// How many overlays the window's stack holds now.
fn ov_open(t : @ui.Tester) -> Int {
  ignore(t)
  @headless.overlays_open(@ui.view_tree().unwrap())
}

///|
test "a modal overlay opened by the keys: read out a Dialog by its name, the focus on its first button, what is under it hidden; Escape tells Escape once, the focus back on what opened it" {
  let k = ov_case()
  k.t.set_a11y(true)
  k.t.act(Button, Focus, label="打开")
  k.t.enter()
  let opened = (
    k.t.query(Dialog, label="设置") is Some(_),
    ov_focus(k.t),
    k.t.query(Button, label="别处").map(fn(s) { s.hidden }).unwrap_or(true),
    ov_open(k.t),
  )
  k.t.key(@ui.key_escape)
  let closed = (k.dialog.get(), ov_focus(k.t), k.t.query(Dialog, label="设置") is Some(_))
  // (Escape again while it goes: nothing more told)
  k.t.key(@ui.key_escape)
  k.t.run_for(ov_leave_ms)
  assert_eq((opened, closed, k.dialog_told, ov_open(k.t)), ((true, "菜单", true, 1), (false, "打开", false), [Escape], 0))
}

///|
test "a press on its own ground is no press outside it; a press elsewhere (what opened it among it, under the modal layer) tells Outside once, nothing under it pressed" {
  let k = ov_case()
  let (ax, ay) = ov_middle(k.t, "打开")
  k.t.click(Button, label="打开")
  let (dx, dy, dw, dh) = k.t.get(Dialog, label="设置").rect
  k.t.tap(dx + dw / 2.0, dy + dh - 10.0)
  let kept = (k.dialog_told.copy(), k.dialog.get())
  k.t.tap(ax, ay)
  assert_eq((kept, k.dialog_told, k.dialog.get(), k.pressed.get("打开")), (([], true), [Outside], false, Some(1)))
}

///|
test "a menu opened on the dialog: the top of the stack; Escape closes the menu alone, the dialog by the next" {
  let k = ov_case()
  k.t.click(Button, label="打开")
  k.t.click(Button, label="菜单")
  let d = k.dialog_state.val.unwrap()
  let m = k.menu_state.val.unwrap()
  let stack = (d.depth(), d.is_top(), m.depth(), m.is_top(), ov_open(k.t))
  k.t.key(@ui.key_escape)
  let first = (k.menu.get(), k.dialog.get(), d.is_top())
  k.t.run_for(ov_leave_ms)
  k.t.key(@ui.key_escape)
  assert_eq((stack, first, k.menu_told, k.dialog_told, k.dialog.get()), (
    (0, false, 1, true, 2),
    (false, true, true),
    [Escape],
    [Escape],
    false,
  ))
}

///|
test "a press on the dialog outside its menu closes the menu alone; a press on the menu's own trigger closes nothing; the system's back closes the dialog after" {
  let k = ov_case()
  k.t.click(Button, label="打开")
  k.t.click(Button, label="菜单")
  let (tx, ty) = ov_middle(k.t, "菜单")
  k.t.press_at(tx, ty)
  let on_trigger = k.menu_told.copy()
  k.t.release(tx, ty)
  let (dx, dy, dw, dh) = k.t.get(Dialog, label="设置").rect
  // (the dialog's ground, under its buttons and over the menu's)
  k.t.tap(dx + dw - 10.0, dy + 90.0)
  let after_tap = (k.menu.get(), k.dialog.get())
  k.t.run_for(ov_leave_ms)
  k.t.back()
  assert_eq((on_trigger, after_tap, k.menu_told, k.dialog_told, dh > 0.0), ([], (false, true), [Outside], [Back], true))
}

///|
test "an inert menu takes nothing and lets all through: its button takes no press, Escape closes the dialog under it, a press on the dialog does not close it" {
  let k = ov_case()
  k.t.click(Button, label="打开")
  k.t.click(Button, label="菜单")
  k.menu_inert.set(true)
  k.t.draw()
  let m = k.menu_state.val.unwrap()
  let d = k.dialog_state.val.unwrap()
  let tops = (m.is_top(), d.is_top(), k.t.query(Dialog, label="菜单项") is Some(_))
  let (cx, cy) = ov_middle(k.t, "确定")
  k.t.tap(cx, cy)
  let on_dialog = (k.menu_told.copy(), k.dialog_told.copy())
  k.t.key(@ui.key_escape)
  assert_eq((tops, on_dialog, k.menu_told, k.dialog_told), ((false, true, false), ([], []), [], [Escape]))
}

///|
test "a layer that takes no Escape (a toast's) over the dialog lets Escape through to it; once all are let go the stack holds none" {
  let k = ov_case()
  k.t.click(Button, label="打开")
  k.toast.set(true)
  k.t.draw()
  let held = ov_open(k.t)
  k.t.key(@ui.key_escape)
  let told = k.dialog_told.copy()
  k.toast.set(false)
  k.t.run_for(ov_leave_ms)
  assert_eq((held, told, k.dialog.get(), ov_open(k.t)), (2, [Escape], false, 0))
}

///|
test "overlay: before_dismiss, keeps, initial_focus, in_node, and bring_to_top on inert->live" {
  let step = @signals.signal(2)
  let ov1_inert = @signals.signal(false)
  let ov1_dismissed : Array[@headless.OverlayDismiss] = []
  let ov2_dismissed : Array[@headless.OverlayDismiss] = []
  let ov1_state : Ref[@headless.Overlay?] = Ref(None)
  let ov2_state : Ref[@headless.Overlay?] = Ref(None)
  let keep_btn : Ref[@view.View?] = Ref(None)
  let t = window(fn(root) {
    let kept = @headless.button(root, fn() { "豁免区" }, fn(_) {  }, fn(v, _) {
      v.width(Is(Some(100.0))).height(Is(Some(32.0))) |> ignore
    })
    keep_btn.val = Some(kept)
    root.box(fn(layer1) {
      layer1
      .over(Is(true))
      .offset(Is((150.0, 20.0)))
      .width(Is(Some(160.0)))
      .height(Is(Some(120.0)))
      .ground(Is(c_rest))
      |> ignore
      @headless.overlay(
        layer1,
        fn(how) { ov1_dismissed.push(how) },
        inert=fn() { ov1_inert.get() },
        in_node=true,
        keeps=fn() {
          match keep_btn.val {
            Some(k) => [k]
            None => []
          }
        },
        before_dismiss=fn(how) {
          if how == Escape && step.untracked() > 1 {
            step.set(step.untracked() - 1)
            true
          } else {
            false
          }
        },
        label=fn() { "层一" },
        fn(_v, o) { ov1_state.val = Some(o) },
      )
      |> ignore
    })
    |> ignore
    root.box(fn(layer2) {
      @headless.overlay(
        layer2,
        fn(how) { ov2_dismissed.push(how) },
        modal=false,
        leaves_typing=true,
        held_back_goes_on=true,
        in_node=true,
        label=fn() { "层二" },
        fn(v, o) {
          ov2_state.val = Some(o)
          v
          .over(Is(true))
          .offset(Is((180.0, 160.0)))
          .width(Is(Some(160.0)))
          .height(Is(Some(100.0)))
          .ground(Is(c_rest))
          |> ignore
          @headless.button(v, fn() { "按钮甲" }, fn(_) {  }, fn(b, _) {
            b.width(Is(Some(80.0))).height(Is(Some(30.0))) |> ignore
          })
          |> ignore
          @headless.button(v, fn() { "按钮乙" }, fn(_) {  }, fn(b, _) {
            b.width(Is(Some(80.0))).height(Is(Some(30.0))) |> ignore
          })
          |> ignore
        },
      )
      |> ignore
    })
    |> ignore
  })
  // Initially layer2 is on top (depth 1), layer1 is below (depth 0).
  let d0 = (ov1_state.val.unwrap().depth(), ov2_state.val.unwrap().depth())
  // Transition layer1 inert -> live brings layer1 to top of stack.
  ov1_inert.set(true)
  t.draw()
  ov1_inert.set(false)
  t.draw()
  let d1 = (ov1_state.val.unwrap().depth(), ov2_state.val.unwrap().depth(), ov1_state.val.unwrap().is_top())
  // Clicking kept button does not dismiss layer1.
  let (kx, ky, kw, kh) = t.get(Button, label="豁免区").rect
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
  let after_kept = ov1_dismissed.copy()
  // First Escape is consumed by before_dismiss (step 2 -> 1), not calling on_dismiss.
  t.key(@ui.key_escape)
  let after_esc1 = (step.get(), ov1_dismissed.copy())
  // Second Escape passes through to on_dismiss.
  t.key(@ui.key_escape)
  let after_esc2 = (step.get(), ov1_dismissed.copy())
  assert_eq(d0, (0, 1))
  assert_eq(d1, (1, 0, true))
  assert_eq(after_kept, [])
  assert_eq(after_esc1, (1, []))
  assert_eq(after_esc2, (1, [Escape]))
}

///|
test "overlay: initial_focus targets specific child and dialog forwards before_dismiss" {
  // Part 1: overlay with explicit initial_focus focuses the second button instead of the first.
  let ov_open = @signals.signal(false)
  let t0 = window(fn(root) {
    @headless.button(root, fn() { "打开层" }, fn(_) { ov_open.set(true) }, fn(v, _) {
      v.width(Is(Some(100.0))).height(Is(Some(32.0))) |> ignore
    })
    |> ignore
    root.show(at_once=true, fn() { ov_open.get() }, fn(layer) {
      layer.over(Is(true)).width(Is(Some(180.0))).height(Is(Some(120.0))).ground(Is(c_rest)) |> ignore
      @headless.button(layer, fn() { "第一按钮" }, fn(_) {  }, fn(b, _) {
        b.width(Is(Some(80.0))).height(Is(Some(30.0))) |> ignore
      })
      |> ignore
      let second = @headless.button(layer, fn() { "第二按钮" }, fn(_) {  }, fn(b, _) {
        b.width(Is(Some(80.0))).height(Is(Some(30.0))) |> ignore
      })
      @headless.overlay(
        layer,
        fn(_) { ov_open.set(false) },
        modal=true,
        initial_focus=second,
        in_node=true,
        label=fn() { "定点焦点层" },
        fn(_, _) {  },
      )
      |> ignore
    })
    |> ignore
  })
  t0.click(Button, label="打开层")
  assert_eq(ov_focus(t0), "第二按钮")

  // Part 2: dialog forwards before_dismiss and leaves_typing.
  let open = @signals.signal(true)
  let blocked = Ref(true)
  let dlg_closes = Ref(0)
  let t = window(fn(root) {
    root.show(at_once=true, fn() { open.get() }, fn(s) {
      @headless.dialog(
        s,
        fn() { "多步弹窗" },
        fn() { open.get() },
        fn() {
          dlg_closes.val += 1
          open.set(false)
        },
        before_dismiss=fn(_) {
          if blocked.val {
            blocked.val = false
            true
          } else {
            false
          }
        },
        leaves_typing=true,
        fn(v, _) {
          v.over(Is(true)).width(Is(Some(160.0))).height(Is(Some(80.0))).ground(Is(c_rest)) |> ignore
        },
      )
      |> ignore
    })
    |> ignore
  })
  t.key(@ui.key_escape)
  let after_first_esc = (open.get(), dlg_closes.val)
  t.key(@ui.key_escape)
  let after_second_esc = (open.get(), dlg_closes.val)
  assert_eq(after_first_esc, (true, 0))
  assert_eq(after_second_esc, (false, 1))
}

