// A control's look as one statement over its states (control_look_node) and an overlay drawn as the library's card
// (overlay_card_node): each state's ground, wash, edge and clearness as the mouse, a finger, the keys and its caller
// change them; and a menu card opened on a modal card, closed by Escape before it, nothing faulted in how either is
// laid out or rounded.

///|
/// The tests' look: its ground `look_ground`, chosen `look_chosen`; washed by the theme's hover; an edge of 1 while the
/// focus shows.
let look_ground : Int64 = 0x223344FFL

///|
let look_chosen : Int64 = 0x445566FFL

///|
fn test_look() -> ControlLook {
  ControlLook::new(
    ground=@headless.StateStyle::new(base=look_ground, selected=look_chosen),
    edge=@headless.StateStyle::new(base=(0.0, 0L), focused=(1.0, look_ground)),
  )
}

///|
/// A window (pointed at by `pointing`): a button "前" and the looked button "钮" (chosen while `chosen`, disabled while
/// `off`), 80 by 40 each; what "钮" reads kept in `read`.
fn look_case(
  chosen : @signals.Signal[Bool],
  off : @signals.Signal[Bool],
  read : Ref[@headless.Button?],
  node : Ref[@view.View?],
  pointing? : @ui.Pointing = Mouse,
) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=300.0, pointing~)
  @ui.set_view_app(fn(root) {
    @headless.button(root, fn() { "前" }, fn(_) {  }, fn(v, _) {
      v.width(Is(Some(80.0))).height(Is(Some(40.0))) |> ignore
    })
    |> ignore
    @headless.button(root, fn() { "钮" }, fn(_) {  }, disabled=fn() { off.get() }, fn(v, b) {
      read.val = Some(b)
      node.val = Some(v)
      v.width(Is(Some(80.0))).height(Is(Some(40.0))) |> ignore
      control_look_node(v, fn() { b.state(selected=chosen.get()) }, test_look)
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// How long the tests' cards take to go (View::show's leave).
let card_leave_ms : Double = 200.0

///|
/// What would close an overlay, as a word.
fn how_word(how : @headless.OverlayDismiss) -> String {
  match how {
    Escape => "Escape"
    Outside => "Outside"
    Back => "Back"
  }
}

///|
/// What node `v` is drawn as now: its ground, its edge and how clear it is.
fn look_drawn(v : @view.View) -> (Int64, (Double, Int64), Double) {
  for d in v.tree.drawn() {
    if d.id == v.id() {
      return (d.ground, d.edge, d.alpha)
    }
  }
  (-1L, (-1.0, -1L), -1.0)
}

///|
test "a look over a button's states: at rest its ground; the mouse over it and pressing it washed with the hover; chosen its chosen ground; the focus shown by the keys its edge; disabled faded and unwashed" {
  let chosen = @signals.signal(false)
  let off = @signals.signal(false)
  let read = Ref(None)
  let node = Ref(None)
  let t = look_case(chosen, off, read, node)
  let b = read.val.unwrap()
  let v = node.val.unwrap()
  let hover = @ui.tree_theme().color(Hover)
  let (x, y, w, h) = t.get(Button, label="钮").rect
  let (cx, cy) = (x + w / 2.0, y + h / 2.0)
  let rest = (look_drawn(v), test_look().at(b.state()).1)
  t.move_to(cx, cy)
  let over = test_look().at(b.state()).1
  t.press_at(cx, cy)
  let held = test_look().at(b.state()).1
  t.release(cx, cy)
  t.move_to(390.0, 290.0)
  chosen.set(true)
  t.draw()
  let picked = look_drawn(v).0
  t.act(Button, Focus, label="前")
  t.tab()
  let keyed = (look_drawn(v).1, test_look().at(b.state()).1)
  off.set(true)
  t.draw()
  let disabled = (look_drawn(v).2, test_look().at(b.state()).1)
  assert_eq((rest, over, held, picked, keyed, disabled, t.audit(), t.corner_faults()), (
    ((look_ground, (0.0, 0L), 1.0), 0L),
    hover,
    hover,
    look_chosen,
    ((1.0, look_ground), hover),
    (control_off_alpha, 0L),
    [],
    [],
  ))
}

///|
test "under a finger a look washes only as it presses: a hover the tree still holds as the hand turns washes nothing" {
  let read = Ref(None)
  let node = Ref(None)
  let t = look_case(@signals.signal(false), @signals.signal(false), read, node, pointing=Finger)
  let b = read.val.unwrap()
  let (x, y, w, h) = t.get(Button, label="钮").rect
  let (cx, cy) = (x + w / 2.0, y + h / 2.0)
  let left_over = test_look().at({ ..b.state(), hovered: true }).1
  t.press_at(cx, cy)
  let held = test_look().at(b.state()).1
  t.release(cx, cy)
  assert_eq((left_over, held), (0L, @ui.tree_theme().color(Hover)))
}

///|
test "a menu card opened on a modal card: Escape closes the menu first, the modal card by the next; a press on the modal card outside the menu closes the menu alone; nothing faulted" {
  let dialog = @signals.signal(false)
  let menu = @signals.signal(false)
  let told : Array[String] = []
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  let size = fn(v : @view.View) { v.width(Is(Some(120.0))).height(Is(Some(40.0))) |> ignore }
  @ui.set_view_app(fn(root) {
    let opener = @headless.button(root, fn() { "打开" }, fn(_) { dialog.set(true) }, fn(v, _) { size(v) })
    root.show(fn() { dialog.get() }, leave=card_leave_ms, fn(s) {
      overlay_card_node(
        s,
        fn(how) {
          told.push("设置 " + how_word(how))
          dialog.set(false)
        },
        modal=true,
        anchor=opener,
        label=fn() { "设置" },
        place=fn(v) { v.over(Is(true)).offset(Is((120.0, 40.0))).width(Is(Some(220.0))).height(Is(Some(200.0))) |> ignore },
        fn(v, _) {
          let trigger = @headless.button(v, fn() { "菜单" }, fn(_) { menu.set(true) }, fn(b, _) { size(b) })
          v.show(fn() { menu.get() }, leave=card_leave_ms, fn(m) {
            overlay_card_node(
              m,
              fn(how) {
                told.push("菜单项 " + how_word(how))
                menu.set(false)
              },
              anchor=trigger,
              label=fn() { "菜单项" },
              place=fn(c) { c.over(Is(true)).offset(Is((0.0, 100.0))).width(Is(Some(160.0))).height(Is(Some(64.0))) |> ignore },
              fn(c, _) { @headless.button(c, fn() { "复制" }, fn(_) {  }, fn(b, _) { size(b) }) |> ignore },
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
  t.draw()
  t.click(Button, label="打开")
  t.click(Button, label="菜单")
  let both = (t.query(Dialog, label="设置") is Some(_), t.query(Dialog, label="菜单项") is Some(_))
  let faults = (t.audit(), t.corner_faults())
  t.key(@ui.key_escape)
  t.run_for(card_leave_ms)
  t.click(Button, label="菜单")
  let (dx, dy, dw, _) = t.get(Dialog, label="设置").rect
  // (the modal card's own ground, right of its button and over the menu)
  t.tap(dx + dw - 20.0, dy + 70.0)
  t.run_for(card_leave_ms)
  let after_tap = (menu.get(), dialog.get())
  t.key(@ui.key_escape)
  t.run_for(card_leave_ms)
  assert_eq((both, faults, after_tap, told, dialog.get(), @headless.overlays_open(@ui.view_tree().unwrap())), (
    (true, true),
    ([], []),
    (false, true),
    ["菜单项 Escape", "菜单项 Outside", "设置 Escape"],
    false,
    0,
  ))
}

///|
test "fullscreen_overlay_node with on_key routes Escape through stack past upper dismiss_on_escape=false overlay" {
  let full = @signals.signal(false)
  let upper = @signals.signal(false)
  let closed = Ref(0)
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  @ui.set_view_app(fn(root) {
    @headless.button(root, fn() { "打开" }, fn(_) {
      full.set(true)
      upper.set(true)
    }, fn(v, _) { v.width(Is(Some(100.0))).height(Is(Some(40.0))) |> ignore })
    |> ignore
    root.show(fn() { full.get() }, fn(v) {
      fullscreen_overlay_node(
        v,
        fn() {
          closed.val += 1
          full.set(false)
        },
        auto_focus=true,
        on_key=fn(k, dismiss_escape) {
          if k.code == @ui.key_escape && k.mods == 0 {
            dismiss_escape()
          } else {
            false
          }
        },
      )
      |> ignore
      @headless.button(v, fn() { "操作" }, fn(_) {  }, fn(b, _) {
        b.width(Is(Some(100.0))).height(Is(Some(40.0))) |> ignore
      })
      |> ignore
    })
    root.show(fn() { upper.get() }, fn(s) {
      @headless.overlay(
        s,
        fn(_) {  },
        dismiss_on_escape=false,
        dismiss_on_outside=false,
        fn(n, _) { n.over(Is(true)).width(Is(Some(120.0))).height(Is(Some(32.0))) |> ignore },
      )
      |> ignore
    })
  })
  t.draw()
  t.click(Button, label="打开")
  assert_eq((full.get(), upper.get(), @headless.overlays_open(@ui.view_tree().unwrap())), (true, true, 2))
  t.key(@ui.key_escape)
  assert_eq((closed.val, full.get(), upper.get(), @headless.overlays_open(@ui.view_tree().unwrap())), (1, false, true, 1))
}
