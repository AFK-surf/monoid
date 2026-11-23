// A finger held still as long as a long press on what asks for a menu (View::on_menu) asks for it, as the secondary
// button's press does (tree_select.mbt's tree_finger_menu): its menu at the hold's moment, felt, the press called off
// (no tap as it is let go, not pressed from then); a finger that scrolls first, or a node whose own gesture takes the
// hold, nothing of the menu's.

///|
/// What the window of finger_menu_tester holds: the column scrolling its rows, each row's presses and menus asked
/// (where in the window), the first row, and the hold of the button in the last box.
priv struct FingerMenu {
  t : Tester
  scroll : @view.Scroll
  pressed : Ref[Int]
  menus : Array[(Double, Double)]
  first : Ref[@view.View?]
  held : Ref[Int]
}

///|
/// A window 400 by 300 by a finger, a column scrolling 300 tall holding first a box 400 by 60 asking for a menu, which
/// holds a button 200 by 60 ("按住") whose own gesture takes a long press (counted in `held`), as a headless button's
/// Hold does; then 10 rows 400 by 60 ("行 0" … "行 9"), each pressed (counted) and asking for a menu.
fn finger_menu_tester() -> FingerMenu {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, pointing=Finger)
  t.check_looks(false)
  let k : FingerMenu = {
    t,
    scroll: @view.Scroll::new(),
    pressed: Ref(0),
    menus: [],
    first: Ref(None),
    held: Ref(0),
  }
  set_view_app(fn(root) {
    root.box(fn(v) {
      v
      .width(Is(Some(400.0)))
      .height(Is(Some(300.0)))
      .scrolls(k.scroll, slop=touch_slop(), fn(col) {
        col.box(fn(b) {
          b.width(Is(Some(400.0))).height(Is(Some(60.0))).on_menu(fn(m) { k.menus.push((m.wx, m.wy)) }) |> ignore
          b.box(fn(h) {
            h
            .width(Is(Some(200.0)))
            .height(Is(Some(60.0)))
            .says(Is(Some(@view.said(Button, label="按住"))))
            .gesture(touch_slop(), tap=fn(_) {  }, hold=(long_press_ms, fn(_) { k.held.val += 1 }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
        for i in 0..<10 {
          col.box(fn(r) {
            if i == 0 {
              k.first.val = Some(r)
            }
            r
            .width(Is(Some(400.0)))
            .height(Is(Some(60.0)))
            .says(Is(Some(@view.said(Button, label="行 \{i}"))))
            .on_press(fn() { k.pressed.val += 1 })
            .on_menu(fn(m) { k.menus.push((m.wx, m.wy)) })
            |> ignore
          })
          |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  k
}

///|
/// Whether the first row is pressed now, as what draws its press reads it.
fn FingerMenu::first_pressed(self : FingerMenu) -> Bool {
  match self.first.val {
    Some(v) => @signals.untracked(fn() { v.pressed() })
    None => false
  }
}

///|
/// A tap's time: well within a long press.
let finger_menu_tap_ms : Double = 100.0

///|
test "a row tapped by a finger: pressed, no menu" {
  let k = finger_menu_tester()
  k.t.touch(0, 150.0, 90.0)
  k.t.run_for(finger_menu_tap_ms)
  k.t.touch(2, 150.0, 90.0)
  k.t.draw()
  assert_eq((k.pressed.val, k.menus.length()), (1, 0))
  assert_eq(k.t.haptics().contains(LongPress), false)
}

///|
test "a row held still by a finger as long as a long press: its menu there then, felt; let go, no press and not pressed" {
  let k = finger_menu_tester()
  k.t.touch(0, 150.0, 90.0)
  k.t.run_for(finger_menu_tap_ms)
  assert_eq(k.first_pressed(), true)
  k.t.run_for(long_press_ms - finger_menu_tap_ms)
  debug_inspect(k.menus, content="[(150, 90)]")
  assert_eq(k.t.haptics().contains(LongPress), true)
  assert_eq(k.first_pressed(), false)
  k.t.touch(2, 150.0, 90.0)
  k.t.draw()
  assert_eq((k.pressed.val, k.menus.length(), k.first_pressed()), (0, 1, false))
}

///|
test "a row a finger scrolls before a long press: scrolled, no menu, no press" {
  let k = finger_menu_tester()
  k.t.touch(0, 150.0, 200.0)
  k.t.run_for(finger_menu_tap_ms)
  k.t.touch(1, 150.0, 170.0)
  k.t.touch(1, 150.0, 120.0)
  k.t.run_for(long_press_ms)
  k.t.touch(2, 150.0, 120.0)
  k.t.run_for(long_press_ms)
  assert_eq(k.scroll.at(view_tree().unwrap()) > 0.0, true)
  assert_eq((k.pressed.val, k.menus.length()), (0, 0))
}

///|
test "a button whose own gesture takes a long press, in a box asking for a menu: its hold, not the box's menu" {
  let k = finger_menu_tester()
  k.t.touch(0, 100.0, 30.0)
  k.t.run_for(long_press_ms)
  k.t.touch(2, 100.0, 30.0)
  k.t.draw()
  assert_eq((k.held.val, k.menus.length(), k.pressed.val), (1, 0, 0))
}

///|
test "the box beside that button held as long as a long press: its own menu" {
  let k = finger_menu_tester()
  k.t.touch(0, 300.0, 30.0)
  k.t.run_for(long_press_ms)
  k.t.touch(2, 300.0, 30.0)
  k.t.draw()
  assert_eq((k.held.val, k.pressed.val), (0, 0))
  debug_inspect(k.menus, content="[(300, 30)]")
}
