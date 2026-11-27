// The headless menu's typeahead, its submenus (@headless.Submenu, Menu::sub_trigger, Submenu::menu) and the context
// menu's trigger (@headless.context_menu), under a look of the tests' own: letters typed within 500 ms of each other
// find an item together, the same letter again the next, a disabled item passed by (each key's own moment: the same at
// any rate of frames); a submenu's trigger read out expanded, opened by → and Enter (the keys into it) and by a press
// (the keys staying), closed by ← and Escape (the keys back on its trigger), opened 180 ms after the pointer rests on
// it and closed 150 ms after it left both, kept while it crossed into the submenu, never opened by a finger's resting;
// a context menu asked for by a right click and a finger's long press, at their points, not by a finger that moved
// first, never while disabled. Each window is made by `window` (window_test.mbt), which holds that menu.mbt,
// submenu.mbt and context_menu.mbt draw and lay out nothing.

///|
/// How long letters typed together find an item (the menu's `typeahead_ms`, its default).
let ma_typed_ms : Double = 500.0

///|
/// A submenu's waits: its own defaults.
let ma_open_ms : Double = 180.0

///|
let ma_close_ms : Double = 150.0

///|
/// The least step of the clock a test takes.
let ma_tick_ms : Double = 1.0

///|
/// What a menu case keeps: its window, whether its submenu is open (the caller's), what was done, and whether its
/// "Blueberry" and its submenu's trigger are disabled.
struct MaCase {
  t : @ui.Tester
  open : @signals.Signal[Bool]
  done : Array[String]
  berry_off : @signals.Signal[Bool]
  more_off : @signals.Signal[Bool]
}

///|
/// A menu "Fruit" of Apple, Banana, Blueberry (disabled while `berry_off`), More (its submenu's trigger), Apricot and
/// Cherry, each 120 by 28 down from the top; while its submenu is open, the menu "More fruit" of "Fig" and "Grape" over
/// the window, 130 right of where it is made and beside More.
fn ma_case(pointing? : @ui.Pointing = Mouse, typeahead? : Bool = true) -> MaCase raise {
  let open = @signals.signal(false)
  let done : Array[String] = []
  let berry_off = @signals.signal(true)
  let more_off = @signals.signal(false)
  let sub = @headless.Submenu::new(fn() { open.get() }, fn(v) { open.set(v) })
  let t = window(pointing~, fn(root) {
    @headless.menu(root, label=fn() { "Fruit" }, typeahead~, fn(m, menu) {
      for name in ["Apple", "Banana", "Blueberry"] {
        menu.item(m, fn() { name }, fn(_) { done.push(name) }, menu_row, disabled=fn() {
          name == "Blueberry" && berry_off.get()
        })
        |> ignore
      }
      menu.sub_trigger(m, sub, fn() { "More" }, menu_row, disabled=fn() { more_off.get() }) |> ignore
      for name in ["Apricot", "Cherry"] {
        menu.item(m, fn() { name }, fn(_) { done.push(name) }, menu_row) |> ignore
      }
    })
    |> ignore
    root.show(fn() { open.get() }, fn(s) {
      sub.menu(s, label=fn() { "More fruit" }, fn(v, menu) {
        v.over(Is(true)).offset(Is((130.0, -84.0))) |> ignore
        for name in ["Fig", "Grape"] {
          menu.item(v, fn() { name }, fn(_) { done.push(name) }, menu_row) |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  { t, open, done, berry_off, more_off }
}

///|
/// The middle of the menu item called `name`.
fn ma_middle(t : @ui.Tester, name : String) -> (Double, Double) {
  let (x, y, w, h) = t.get(MenuItem, label=name).rect
  (x + w / 2.0, y + h / 2.0)
}

///|
/// The letter `c` typed (its key, as a keyboard's is told).
fn ma_type(t : @ui.Tester, c : Char) -> Unit {
  t.key(@ui.key_of_char(c))
}

///|
test "a menu's typeahead: letters within 500 ms of each other find together; the same letter again goes on to the next, a disabled item passed by; past 500 ms what is typed begins anew; nothing done; off where typeahead is" {
  let k = ma_case()
  k.t.act(MenuItem, Focus, label="Apple")
  // (b: Banana; b again within 500 ms: Blueberry disabled, passed by, around to Banana)
  ma_type(k.t, 'b')
  let b = focus_name(k.t)
  k.t.run_for(ma_typed_ms - ma_tick_ms)
  ma_type(k.t, 'b')
  let bb = focus_name(k.t)
  // (c, then h 499 ms after: "ch", Cherry)
  k.t.run_for(ma_typed_ms + ma_tick_ms)
  ma_type(k.t, 'c')
  k.t.run_for(ma_typed_ms - ma_tick_ms)
  ma_type(k.t, 'h')
  let ch = focus_name(k.t)
  // (a: around to Apple; a again: Apricot; a again: Apple)
  k.t.run_for(ma_typed_ms + ma_tick_ms)
  ma_type(k.t, 'a')
  let a1 = focus_name(k.t)
  ma_type(k.t, 'a')
  let a2 = focus_name(k.t)
  ma_type(k.t, 'a')
  let a3 = focus_name(k.t)
  // (past 500 ms: "m" alone, More, the submenu's trigger, not opened; Shift with a letter as without: B, Banana)
  k.t.run_for(ma_typed_ms + ma_tick_ms)
  ma_type(k.t, 'm')
  let m = (focus_name(k.t), k.open.get())
  k.t.run_for(ma_typed_ms + ma_tick_ms)
  k.t.key(@ui.key_of_char('b'), mods=@ui.mod_shift_key)
  let shifted = focus_name(k.t)
  // (Blueberry enabled: b from Banana comes to it)
  k.berry_off.set(false)
  k.t.frame()
  k.t.run_for(ma_typed_ms + ma_tick_ms)
  ma_type(k.t, 'b')
  let berry = focus_name(k.t)
  assert_eq(
    (b, bb, ch, a1, a2, a3, m, shifted, berry, k.done.length()),
    ("Banana", "Banana", "Cherry", "Apple", "Apricot", "Apple", ("More", false), "Banana", "Blueberry", 0),
  )
  // typeahead off: a letter moves nothing
  let off = ma_case(typeahead=false)
  off.t.act(MenuItem, Focus, label="Apple")
  ma_type(off.t, 'c')
  assert_eq(focus_name(off.t), "Apple")
}

///|
test "a submenu by the keys: its trigger read out a MenuItem expanded false; → opens it, the keys on its first item; ← closes it, the keys back on the trigger; Enter opens it the same; Escape closes it the same; disabled, → opens nothing" {
  let k = ma_case()
  let closed = k.t.get(MenuItem, label="More").expanded
  k.t.act(MenuItem, Focus, label="Apple")
  k.t.key(@ui.key_code_down)
  k.t.key(@ui.key_code_down)
  let on_more = focus_name(k.t)
  k.t.key(@ui.key_code_right)
  let by_right = (k.open.get(), k.t.get(MenuItem, label="More").expanded, focus_name(k.t), k.t.query(Menu, label="More fruit") is Some(_))
  k.t.key(@ui.key_code_down)
  let in_sub = focus_name(k.t)
  k.t.key(@ui.key_code_left)
  let by_left = (k.open.get(), focus_name(k.t), k.t.focused().map(fn(s) { s.focused }).unwrap_or(false))
  k.t.enter()
  let by_enter = (k.open.get(), focus_name(k.t))
  k.t.key(@ui.key_escape)
  let by_escape = (k.open.get(), focus_name(k.t))
  k.more_off.set(true)
  k.t.frame()
  k.t.key(@ui.key_code_right)
  let off = k.open.get()
  assert_eq(
    (closed, on_more, by_right, in_sub, by_left, by_enter, by_escape, off, k.done.length()),
    (
      Some(false),
      "More",
      (true, Some(true), "Fig", true),
      "Grape",
      (false, "More", true),
      (true, "Fig"),
      (false, "More"),
      false,
      0,
    ),
  )
}

///|
test "a submenu by the pointer: closed 179 ms after it rests on the trigger, open at 180; crossing into the submenu keeps it; leaving both, open 149 ms after, closed at 150; leaving before 180 ms opens none; a press opens it at once, the keys staying" {
  let k = ma_case()
  let (mx, my) = ma_middle(k.t, "More")
  k.t.move_to(mx, my)
  k.t.run_for(ma_open_ms - ma_tick_ms)
  let before = k.open.get()
  k.t.run_for(ma_tick_ms)
  let at = k.open.get()
  // (onto the submenu's Fig: kept however long)
  let (fx, fy) = ma_middle(k.t, "Fig")
  k.t.move_to(fx, fy)
  k.t.run_for(ma_close_ms * 4.0)
  let kept = k.open.get()
  // (onto Cherry, a sibling of the trigger: closed 150 ms after)
  let (cx, cy) = ma_middle(k.t, "Cherry")
  k.t.move_to(cx, cy)
  k.t.run_for(ma_close_ms - ma_tick_ms)
  let lingering = k.open.get()
  k.t.run_for(ma_tick_ms)
  let gone = k.open.get()
  // (onto the trigger and off it within 180 ms: none)
  k.t.move_to(mx, my)
  k.t.run_for(ma_open_ms / 2.0)
  k.t.move_to(cx, cy)
  k.t.run_for(ma_open_ms * 2.0)
  let never = k.open.get()
  // (a click on it: open at once, the keys not into it)
  k.t.click(MenuItem, label="More")
  let clicked = (k.open.get(), focus_name(k.t) != "Fig")
  assert_eq((before, at, kept, lingering, gone, never, clicked), (false, true, true, true, false, false, (true, true)))
}

///|
test "a submenu disabled as it is open closes at once; the pointer resting on a disabled trigger opens nothing" {
  let k = ma_case()
  let (mx, my) = ma_middle(k.t, "More")
  k.t.move_to(mx, my)
  k.t.run_for(ma_open_ms)
  let open = k.open.get()
  k.more_off.set(true)
  k.t.frame()
  let closed = k.open.get()
  k.t.move_to(390.0, 290.0)
  k.t.run_for(ma_close_ms)
  k.t.move_to(mx, my)
  k.t.run_for(ma_open_ms * 2.0)
  assert_eq((open, closed, k.open.get()), (true, false, false))
}

///|
test "a finger opens a submenu by its press alone: held on the trigger it opens none while it rests, nothing waited for; let go on it, or a tap, opens it, the keys staying" {
  let k = ma_case(pointing=Finger)
  let (mx, my) = ma_middle(k.t, "More")
  k.t.press_at(mx, my)
  k.t.run_for(ma_open_ms * 2.0)
  let held = k.open.get()
  k.t.release(mx, my)
  let let_go = k.open.get()
  k.open.set(false)
  k.t.frame()
  k.t.run_for(ma_open_ms * 2.0)
  let (cx, cy) = ma_middle(k.t, "Cherry")
  k.t.tap(cx, cy)
  let done = k.done.copy()
  k.t.tap(mx, my)
  k.t.run_for(ma_close_ms * 4.0)
  assert_eq((held, let_go, done, k.open.get(), focus_name(k.t) != "Fig"), (false, true, ["Cherry"], true, true))
}

///|
/// What a context menu case keeps: its window, where its menu was asked for (in the area's terms and the window's),
/// and whether it is disabled.
struct CmCase {
  t : @ui.Tester
  asked : Array[(Double, Double, Double, Double)]
  off : @signals.Signal[Bool]
}

///|
/// A window: a button "上" 400 by 40, under it an area 400 by 120 asking for a context menu (its slot itself where
/// `in_node`, made by View::each), holding a button "里" 100 by 40.
fn cm_case(pointing? : @ui.Pointing = Mouse, in_node? : Bool = false) -> CmCase raise {
  let asked = []
  let off = @signals.signal(false)
  let size = fn(v : @view.View, w : Double, h : Double) { v.width(Is(Some(w))).height(Is(Some(h))) |> ignore }
  let area = fn(parent : @view.View, in_node : Bool) {
    @headless.context_menu(
      parent,
      in_node~,
      disabled=fn() { off.get() },
      fn(m) { asked.push((m.x, m.y, m.wx, m.wy)) },
      fn(v) {
        size(v, 400.0, 120.0)
        @headless.button(v, fn() { "里" }, fn(_) {  }, fn(b, _) { size(b, 100.0, 40.0) }) |> ignore
      },
    )
    |> ignore
  }
  let t = window(pointing~, fn(root) {
    @headless.button(root, fn() { "上" }, fn(_) {  }, fn(v, _) { size(v, 400.0, 40.0) }) |> ignore
    if in_node {
      root.each(fn() { ["区"] }, fn(k) { k }, fn(slot, _) { area(slot, true) })
    } else {
      area(root, false)
    }
  })
  { t, asked, off }
}

///|
/// A tap's time: well within a long press.
let cm_tap_ms : Double = 100.0

///|
test "a context menu asked for by a right click: told where, in the area's terms and the window's; on a button it holds, the area's; disabled, nothing; above it, nothing" {
  let k = cm_case()
  k.t.right_click(250.0, 100.0)
  k.t.right_click(50.0, 60.0)
  k.t.right_click(50.0, 20.0)
  k.off.set(true)
  k.t.frame()
  k.t.right_click(250.0, 100.0)
  debug_inspect(k.asked, content="[(250, 60, 250, 100), (50, 20, 50, 60)]")
}

///|
test "a context menu in the slot a structure made (in_node) is that slot: asked for by a right click there" {
  let k = cm_case(in_node=true)
  k.t.right_click(250.0, 100.0)
  debug_inspect(k.asked, content="[(250, 60, 250, 100)]")
}

///|
test "a context menu asked for by a finger held still as long as a long press, where it is held; a tap asks none; a finger moved past the slop first asks none; disabled, nothing" {
  let k = cm_case(pointing=Finger)
  // (a tap)
  k.t.touch(0, 250.0, 100.0)
  k.t.run_for(cm_tap_ms)
  k.t.touch(2, 250.0, 100.0)
  k.t.draw()
  let tapped = k.asked.length()
  // (held as long as a long press)
  k.t.touch(0, 250.0, 100.0)
  k.t.run_for(cm_tap_ms)
  k.t.run_for(@ui.long_press_ms - cm_tap_ms)
  let held = k.asked.copy()
  k.t.touch(2, 250.0, 100.0)
  k.t.draw()
  // (moved 40 across first, then held)
  k.t.touch(0, 250.0, 100.0)
  k.t.run_for(cm_tap_ms)
  k.t.touch(1, 290.0, 100.0)
  k.t.run_for(@ui.long_press_ms * 2.0)
  k.t.touch(2, 290.0, 100.0)
  k.t.draw()
  let moved = k.asked.length()
  // (disabled, held)
  k.off.set(true)
  k.t.frame()
  k.t.touch(0, 250.0, 100.0)
  k.t.run_for(@ui.long_press_ms * 2.0)
  k.t.touch(2, 250.0, 100.0)
  k.t.draw()
  assert_eq((tapped, held, moved, k.asked.length()), (0, [(250.0, 60.0, 250.0, 100.0)], 1, 1))
}

///|
test "a menu's typeahead from nowhere (a menu the pointer opened) finds from its first item; never with the keys on what else it holds (a field in it), whose letters are its own" {
  let t = window(fn(root) {
    @headless.menu(root, label=fn() { "Find" }, fn(m, menu) {
      m.box(fn(f) {
        f
        .width(Is(Some(120.0)))
        .height(Is(Some(28.0)))
        .presses(Is(true))
        .focusable(Is(true), keys=0)
        .says(Is(Some(@view.said(TextField, label="Filter"))))
        |> ignore
      })
      |> ignore
      for name in ["Apple", "Cherry"] {
        menu.item(m, fn() { name }, fn(_) {  }, menu_row) |> ignore
      }
    })
    |> ignore
  })
  ma_type(t, 'c')
  let from_nowhere = focus_name(t)
  t.act(TextField, Focus, label="Filter")
  t.run_for(ma_typed_ms + ma_tick_ms)
  ma_type(t, 'a')
  assert_eq((from_nowhere, focus_name(t)), ("Cherry", "Filter"))
}
