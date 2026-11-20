// The secondary and middle buttons taken whole by a node that asks for them (View::on_buttons): down, the moves while
// held, up, beside the primary button's drag; a node that does not ask keeps its menu, and a middle button nothing
// takes does nothing.

///|
/// A pad 300 by 200 at the window's top left that takes a drag (counted in `drags`), with a menu (counted in `menus`)
/// and, where `whole`, the other buttons whole (each event said in `said`); beside it, at x 320, a button with a menu
/// of its own (counted in `menus` too).
fn buttons_pad(drags : Ref[Int], menus : Ref[Int], said : Array[String], whole : Bool) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=500.0, h=300.0)
  set_view_app(fn(root) {
    root.box(fn(row) {
      row.row(Is(true)) |> ignore
      row.box(fn(p) {
        p
        .width(Is(Some(300.0)))
        .height(Is(Some(200.0)))
        .says(Is(Some(@view.said(Button, label="Pad"))))
        .on_drag(fn(d) {
          drags.val = drags.val + 1
          match d.kind {
            @view.DragIs::Down => said.push("drag Down")
            @view.DragIs::Up => said.push("drag Up")
            _ => said.push("drag")
          }
        })
        .on_menu(fn(_) { menus.val = menus.val + 1 })
        |> ignore
        if whole {
          p.on_buttons(fn(b) { said.push("\{went_name(b.went)} \{b.button} \{b.held} \{b.x.to_int()},\{b.y.to_int()}") })
          |> ignore
        }
      })
      |> ignore
      row.box(fn(b) {
        b
        .width(Is(Some(80.0)))
        .height(Is(Some(40.0)))
        .says(Is(Some(@view.said(Button, label="More"))))
        .on_press(fn() {  })
        .on_menu(fn(_) { menus.val = menus.val + 1 })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
fn went_name(w : @view.ButtonWent) -> String {
  match w {
    ButtonDown => "ButtonDown"
    ButtonMoved => "ButtonMoved"
    ButtonUp => "ButtonUp"
  }
}

///|
test "the right button held on what takes it whole: down, moves, the left's drag beside it, up; no menu" {
  let drags = Ref(0)
  let menus = Ref(0)
  let said : Array[String] = []
  let t = buttons_pad(drags, menus, said, true)
  t.move_to(50.0, 50.0)
  t.button_down(50.0, 50.0, 2)
  t.move_to(60.0, 70.0)
  t.press_at(60.0, 70.0)
  t.release(60.0, 70.0)
  t.button_up(60.0, 70.0, 2)
  assert_eq(menus.val, 0)
  assert_eq(said.filter(fn(s) { s != "drag" }), [
    "ButtonDown 2 2 50,50", "ButtonMoved 0 2 60,70", "drag Down", "drag Up", "ButtonUp 2 0 60,70",
  ])
  // the middle with the right: both held, each let go in turn
  said.clear()
  t.button_down(10.0, 10.0, 2)
  t.button_down(10.0, 10.0, 3)
  t.button_up(10.0, 10.0, 2)
  t.button_up(10.0, 10.0, 3)
  assert_eq(said, ["ButtonDown 2 2 10,10", "ButtonDown 3 6 10,10", "ButtonUp 2 4 10,10", "ButtonUp 3 0 10,10"])
  // (beside it, a button with a menu: its menu, as ever)
  t.right_click(340.0, 20.0)
  assert_eq(menus.val, 1)
  // moved with nothing held: nothing told
  said.clear()
  t.move_to(100.0, 100.0)
  assert_eq(said, [])
}

///|
test "what does not take the buttons whole keeps its menu; a middle button there does nothing" {
  let drags = Ref(0)
  let menus = Ref(0)
  let said : Array[String] = []
  let t = buttons_pad(drags, menus, said, false)
  t.right_click(50.0, 50.0)
  assert_eq(menus.val, 1)
  t.button_down(50.0, 50.0, 3)
  t.move_to(80.0, 80.0)
  t.button_up(80.0, 80.0, 3)
  assert_eq((menus.val, drags.val, said), (1, 0, []))
}

///|
test "on_middle takes only the middle button and coexists with on_menu and on_press" {
  let presses = Ref(0)
  let menus = Ref(0)
  let said : Array[String] = []
  let t = Tester::new(fn(_c) {  }, w=400.0, h=200.0)
  set_view_app(fn(root) {
    root.box(fn(p) {
      p
      .width(Is(Some(200.0)))
      .height(Is(Some(100.0)))
      .says(Is(Some(@view.said(Button, label="Tab"))))
      .on_press(fn() { presses.val = presses.val + 1 })
      .on_menu(fn(_) { menus.val = menus.val + 1 })
      .on_middle(fn(b) { said.push("\{went_name(b.went)} \{b.button} \{b.held}") })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  // Right click opens menu without firing on_middle
  t.right_click(40.0, 40.0)
  assert_eq((menus.val, presses.val, said), (1, 0, []))
  // Middle button down -> move -> up fires on_middle only
  t.button_down(40.0, 40.0, 3)
  t.move_to(60.0, 50.0)
  t.button_up(60.0, 50.0, 3)
  assert_eq(menus.val, 1)
  assert_eq(presses.val, 0)
  assert_eq(said, ["ButtonDown 3 4", "ButtonMoved 0 4", "ButtonUp 3 0"])
  // While middle is held, a right click is not hijacked by on_middle and still triggers on_menu
  said.clear()
  t.button_down(40.0, 40.0, 3)
  t.right_click(40.0, 40.0)
  t.button_up(40.0, 40.0, 3)
  assert_eq(menus.val, 2)
  assert_eq(presses.val, 0)
  assert_eq(said, ["ButtonDown 3 4", "ButtonUp 3 0"])
}
