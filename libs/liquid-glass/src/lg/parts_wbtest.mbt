// The library's parts as the hand, the keys and a screen reader meet them: each read out as its role, pressed, dragged
// and turned by keys; its glass's springs where their closed forms put them; the overview held to mbui's audit; and a
// drag of each glass part drawn the same at 60, 120, 24 and 7 frames a second.

///|
/// A Tester of a `w` × `h` window, `make` making its tree in the library's theme over a grey (near black in the dark),
/// drawn.
fn lg_case(make : (@view.View) -> Unit, dark? : Bool = false, w? : Double = 800.0, h? : Double = 600.0) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w~, h~, platform=0)
  set_dark(Some(dark))
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme)
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((40.0, 40.0, 40.0, 40.0))).gap(Is(24.0)).lines_up(Is(Some(Start))).ground(By(fn() { if is_dark() { 0x202024FFL } else { 0x8899AAFFL } }))
      |> ignore
      make(page)
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// The middle of a node read out as `role` named `label`.
fn middle(t : @ui.Tester, role : @view.Role, label : String) -> (Double, Double) raise {
  let (x, y, w, h) = t.get(role, label~).rect
  (x + w / 2.0, y + h / 2.0)
}

///|
test "a liquid button is pressed by a tap, by Activate and by Tab then Enter; a drag let go off it presses nothing" {
  let pressed = Ref(0)
  let t = lg_case(fn(p) { liquid_button_node(p, fn() { "Send" }, fn() { pressed.val += 1 }) |> ignore })
  let (x, y) = middle(t, Button, "Send")
  t.tap(x, y)
  t.act(Button, Activate, label="Send")
  t.tab()
  t.enter()
  let after_keys = pressed.val
  t.drag(x, y, x + 400.0, y + 200.0)
  t.run_for(springs_out)
  assert_eq((after_keys, pressed.val, t.get(Button, label="Send").rect.3), (3, 3, button_h))
}

///|
test "a liquid button lit where a finger holds it: its light comes up, follows the finger and goes as it lets go" {
  let light = InteractiveHighlight::new()
  let t = lg_case(fn(p) { liquid_button_node(p, fn() { "Send" }, fn() {  }, light~) |> ignore })
  let (x, y, w, h) = t.get(Button, label="Send").rect
  t.touch(0, x + 10.0, y + h / 2.0)
  t.run_for(springs_out)
  let node = light.node.val.unwrap()
  let held = (light.pressed(node) > 0.99, light.spot(node, w, h).0 < 20.0)
  t.touch(1, x + 60.0, y + h / 2.0)
  t.run_for(a_frame)
  let (dx, _) = light.offset(node)
  let (tx, _, sx, sy) = light.stretch(node)
  t.touch(2, x + 60.0, y + h / 2.0)
  t.run_for(springs_out)
  assert_eq(
    (held, dx > 0.0, tx > 0.0, sx > sy, light.pressed(node) < 0.001),
    ((true, true), true, true, true, true),
  )
}

///|
test "a liquid toggle turns by a tap, by Space and by Activate, and a drag past half its way turns it" {
  let on = @signals.signal(false)
  let t = lg_case(fn(p) { liquid_toggle_node(p, fn() { on.get() }, fn(v) { on.set(v) }, fn() { "Wi-Fi" }) |> ignore })
  let (x, y, _, h) = t.get(Switch, label="Wi-Fi").rect
  t.tap(x + 20.0, y + h / 2.0)
  t.run_for(springs_out)
  let tapped = (on.get(), t.get(Switch, label="Wi-Fi").check)
  t.tab()
  t.key(@ui.key_space)
  t.run_for(springs_out)
  let spaced = on.get()
  t.act(Switch, Activate, label="Wi-Fi")
  t.run_for(springs_out)
  let acted = on.get()
  // (off now: dragged right 15 of its 20 it turns on; back 5, short of half its way, it stays on)
  t.act(Switch, Activate, label="Wi-Fi")
  t.run_for(springs_out)
  t.drag(x + 22.0, y + h / 2.0, x + 37.0, y + h / 2.0)
  t.run_for(springs_out)
  let dragged = on.get()
  // (back 9: short of half its way, and past a drag's slop, under which it would be a tap)
  t.drag(x + 42.0, y + h / 2.0, x + 33.0, y + h / 2.0)
  t.run_for(springs_out)
  assert_eq((tapped, spaced, acted, dragged, on.get()), ((true, Some(On)), false, true, true, true))
}

///|
test "a liquid toggle's thumb is glass while held and white at rest, and goes across as it turns" {
  let on = @signals.signal(false)
  let drag = DampedDrag::new(0.0, lo=0.0, hi=1.0, held_scale=thumb_held_scale)
  let t = lg_case(fn(p) { liquid_toggle_node(p, fn() { on.get() }, fn(v) { on.set(v) }, fn() { "Wi-Fi" }, drag~) |> ignore })
  let node = drag.node.val.unwrap()
  let rest = (drag.pressed(node), drag.jelly(node, 50.0))
  let (x, y, _, h) = t.get(Switch, label="Wi-Fi").rect
  t.touch(0, x + 20.0, y + h / 2.0)
  t.run_for(springs_out)
  let held = (drag.pressed(node) > 0.999, drag.jelly(node, 50.0).0 > 1.49)
  t.touch(2, x + 20.0, y + h / 2.0)
  t.run_for(springs_out)
  assert_eq((rest, held, drag.pressed(node) < 0.001, drag.value(node) > 0.999), ((0.0, (1.0, 1.0)), (true, true), true, true))
}

///|
test "a liquid slider is moved by its keys, by a drag of its thumb and by a tap on its track" {
  let level = @signals.signal(50.0)
  let t = lg_case(fn(p) {
    p.box(fn(b) {
      b.width(Is(Some(400.0))) |> ignore
      liquid_slider_node(b, fn() { level.get() }, fn(v) { level.set(v) }, fn() { "Volume" }) |> ignore
    })
    |> ignore
  })
  let (x, y, w, h) = t.get(Slider, label="Volume").rect
  t.tab()
  t.key(4)
  let keyed = level.get()
  t.key(8)
  let home = level.get()
  t.run_for(springs_out)
  // (its thumb at the start: dragged 100 of its 400, a quarter of its way)
  t.drag(x + 5.0, y + h / 2.0, x + 105.0, y + h / 2.0)
  t.run_for(springs_out)
  let dragged = level.get()
  t.tap(x + w * 0.75, y + h / 2.0)
  t.run_for(springs_out)
  assert_eq((keyed, home, dragged.round(), level.get().round(), w), (51.0, 0.0, 25.0, 75.0, 400.0))
}

///|
test "liquid bottom tabs: a tab is chosen by a press, by the arrow keys and by the lens dragged over it" {
  let chosen = @signals.signal(0)
  let t = lg_case(fn(p) {
    p.box(fn(b) {
      b.width(Is(Some(408.0))) |> ignore
      liquid_bottom_tabs_node(b, ["Home", "Search", "Me"], fn() { chosen.get() }, fn(i) { chosen.set(i) }, label="Tabs")
      |> ignore
    })
    |> ignore
  })
  let tabs = t.all(Tab).length()
  t.act(Tab, Activate, label="Me")
  t.run_for(springs_out)
  let pressed = (chosen.get(), t.get(Tab, label="Me").selected)
  t.tab()
  t.key(3)
  t.run_for(springs_out)
  let keyed = chosen.get()
  // (the lens over "Search": dragged a tab and a half left, it settles on "Home")
  let (x, y) = middle(t, Tab, "Search")
  t.drag(x, y, x - 200.0, y)
  t.run_for(springs_out)
  assert_eq((tabs, pressed, keyed, chosen.get(), t.get(Tab, label="Home").selected), (3, (2, Some(true)), 1, 0, Some(true)))
}

///|
test "a liquid dialog is read out a dialog while open, and goes by Escape, by Cancel and by its action" {
  let open = @signals.signal(true)
  let acted = Ref(0)
  let t = lg_case(fn(p) {
    liquid_dialog_node(p, fn() { open.get() }, fn() { open.set(false) }, fn() { "Delete?" }, fn() { "It cannot be undone." }, on_action=fn() {
      acted.val += 1
      open.set(false)
    })
    |> ignore
  })
  let shown = t.all(Dialog, label="Delete?").length()
  t.key(@ui.key_escape)
  t.run_for(springs_out)
  let escaped = (open.get(), t.all(Dialog, label="Delete?").length())
  open.set(true)
  t.run_for(springs_out)
  t.act(Button, Activate, label="Cancel")
  t.run_for(springs_out)
  let cancelled = open.get()
  open.set(true)
  t.run_for(springs_out)
  t.act(Button, Activate, label="Okay")
  t.run_for(springs_out)
  assert_eq((shown, escaped, cancelled, open.get(), acted.val), (1, (false, 0), false, false, 1))
}

///|
test "a damped drag's springs: held it grows to its held scale and is squeezed as it goes, let go once near its aim" {
  let drag = DampedDrag::new(0.0, lo=0.0, hi=1.0, held_scale=1.5)
  let n = Ref(None)
  let t = lg_case(fn(p) { p.box(fn(b) { n.val = Some(b) }) |> ignore })
  let node = n.val.unwrap()
  drag.attach(node)
  t.by_hand(fn() {
    drag.press()
    drag.update_value(0.5)
  })
  t.run_for(a_frame)
  t.by_hand(fn() { drag.update_value(1.0) })
  t.run_for(a_frame)
  // (going right fast: wider, flatter)
  let (sx, sy) = drag.jelly(node, 50.0)
  let going = (drag.velocity(node) > 0.0, sx > drag.scale_x.shown(node), sy < drag.scale_y.shown(node))
  t.by_hand(fn() { drag.release() })
  t.run_for(springs_out * 2.0)
  assert_eq(
    (going, drag.value(node), drag.pressed(node), drag.jelly(node, 50.0), drag.velocity(node)),
    ((true, true, true), 1.0, 0.0, (1.0, 1.0), 0.0),
  )
}

///|
test "every part at rest, light and dark, holds to mbui's audit" {
  let faults = []
  for dark in [false, true] {
    let t = lg_case(dark~, w=1000.0, h=900.0, fn(p) {
      p.box(fn(r) {
        r.row(Is(true)).gap(Is(12.0)).lines_up(Is(Some(Middle))) |> ignore
        liquid_button_node(r, fn() { "Plain" }, fn() {  }) |> ignore
        // (a tint dark enough for its white words: the catalog's own blue, 0088FF, is 3.5:1 under them)
        liquid_button_node(r, fn() { "Tinted" }, fn() {  }, tint=0x0050B0FFL) |> ignore
        liquid_toggle_node(r, fn() { true }, fn(_) {  }, fn() { "Toggle" }) |> ignore
      })
      |> ignore
      // (the control center's white over the page it dims, as the catalog's: black at 40% over it)
      p.box(fn(r) {
        r.row(Is(true)).gap(Is(12.0)).padding(Is((12.0, 12.0, 12.0, 12.0))).lines_up(Is(Some(Middle))).ground(Is(0x202024FFL)) |> ignore
        liquid_control_tile_node(r, fn() { "Flight" }, fn() {  }) |> ignore
        liquid_control_item_node(r, fn() { false }, fn(_) {  }, fn() { "Airplane" }) |> ignore
      })
      |> ignore
      p.box(fn(b) {
        b.width(Is(Some(400.0))).gap(Is(16.0)) |> ignore
        liquid_slider_node(b, fn() { 30.0 }, fn(_) {  }, fn() { "Slider" }) |> ignore
        liquid_bottom_tabs_node(b, ["A", "B", "C"], fn() { 1 }, fn(_) {  }, label="Tabs") |> ignore
      })
      |> ignore
      p.box(fn(r) {
        r.row(Is(true)).gap(Is(12.0)) |> ignore
        // (as light as what it is over: the test's grey, near black in the dark)
        liquid_adaptive_surface_node(r, fn() { if dark { 0.1 } else { 0.8 } }) |> ignore
        liquid_card_node(r, 152.0, 68.0, fn() { "Card" }) |> ignore
      })
      |> ignore
      // (the progressive blur's words in the light alone: in the dark the catalog sets white over its grey tint,
      // 3.9:1)
      if !dark {
        p.box(fn(b) {
          b.width(Is(Some(400.0))) |> ignore
          liquid_progressive_blur_node(b) |> ignore
        })
        |> ignore
      }
    })
    t.run_for(springs_out)
    for f in t.audit() {
      faults.push((dark, f))
    }
  }
  assert_eq(faults, [])
}

///|
/// What each glass part draws at declared moments of the same drags, the glass's
/// boxes, rounded to a hundredth of a point.
fn glass_at() -> Array[String] raise {
  let on = @signals.signal(false)
  let level = @signals.signal(20.0)
  let tab = @signals.signal(0)
  let t = lg_case(fn(p) {
    liquid_toggle_node(p, fn() { on.get() }, fn(v) { on.set(v) }, fn() { "Toggle" }) |> ignore
    p.box(fn(b) {
      b.width(Is(Some(400.0))).gap(Is(24.0)) |> ignore
      liquid_slider_node(b, fn() { level.get() }, fn(v) { level.set(v) }, fn() { "Slider" }) |> ignore
      liquid_bottom_tabs_node(b, ["A", "B", "C", "D"], fn() { tab.get() }, fn(i) { tab.set(i) }, label="Tabs") |> ignore
    })
    |> ignore
    liquid_button_node(p, fn() { "Button" }, fn() {  }) |> ignore
  })
  let out = []
  let seen = fn() {
    let g = t.drawn_glass()
    let r = fn(x : Double) { (x * 100.0).round() / 100.0 }
    out.push(g.map(fn(e) { "\{r(e.0)},\{r(e.1)},\{r(e.2)},\{r(e.3)}" }).join(" "))
  }
  let (tx, ty, _, th) = t.get(Switch, label="Toggle").rect
  let (sx, sy, sw, sh) = t.get(Slider, label="Slider").rect
  let (bx, by, _, bh) = t.get(Button, label="Button").rect
  let (ax, ay, aw, ah) = t.all(Tab)[0].rect
  t.touch(0, tx + 20.0, ty + th / 2.0)
  t.run_for(held_ms)
  seen()
  t.touch(2, tx + 20.0, ty + th / 2.0)
  t.run_for(letting_go_ms)
  seen()
  t.run_for(springs_out)
  seen()
  t.drag(sx + sw * 0.2, sy + sh / 2.0, sx + sw * 0.7, sy + sh / 2.0)
  t.run_for(dragged_ms)
  seen()
  t.run_for(springs_out)
  seen()
  t.drag(ax + aw / 2.0, ay + ah / 2.0, ax + aw * 2.6, ay + ah / 2.0)
  t.run_for(dragged_ms)
  seen()
  t.run_for(springs_out)
  seen()
  t.drag(bx + 10.0, by + bh / 2.0, bx + 60.0, by + bh / 2.0)
  t.run_for(dragged_ms)
  seen()
  t.run_for(springs_out)
  seen()
  out.push("\{on.get()} \{level.get().round()} \{tab.get()}")
  out
}

///|
/// What glass_at draws, as the run at the default rate drew it: the runs at 60, 120, 24 and 7 frames a second
/// (MBUI_TEST_FPS) each held to it, to a hundredth of a point.
// (the toggle's thumb held, then let go and gone on; the slider's thumb dragged, then at rest; the tabs' lens dragged,
// grown and squeezed, then on the third tab; the button pulled, stretched, then back)
let glass_seen : Array[String] = [
  "32.94,36.97,58.12,34.06 100,92,40,24 40,140,400,64 44,144,98,56 40,228,77,48",
  "46.59,35.79,61.88,36.42 100,92,40,24 40,140,400,64 44,144,98,56 40,228,77,48",
  "62,42,40,24 100,92,40,24 40,140,400,64 44,144,98,56 40,228,77,48",
  "62,42,40,24 275.94,87.49,76.04,33.03 40,140,400,64 44,144,98,56 40,228,77,48",
  "62,42,40,24 300,92,40,24 40,140,400,64 44,144,98,56 40,228,77,48",
  "62,42,40,24 300,92,40,24 33.75,138.8,414.95,66.39 209.25,133.81,151.6,76.38 40,228,77,48",
  "62,42,40,24 300,92,40,24 40,140,400,64 240,144,98,56 40,228,77,48",
  "62,42,40,24 300,92,40,24 40,140,400,64 240,144,98,56 39.42,227.61,78.75,48.78",
  "62,42,40,24 300,92,40,24 40,140,400,64 240,144,98,56 40,228,77,48",
  "true 70 2",
]

///|
test "a drag of each glass part is drawn the same at 60, 120, 24 and 7 frames a second" {
  assert_eq(glass_at(), glass_seen)
}

///|
/// Long past every spring of the parts' (the softest, InteractiveHighlight's 0.5 at 300, is within its threshold in
/// well under a second): what a step waits before what it asserts of a part at rest.
let springs_out : Double = 1000.0

///|
/// A frame at 60 frames a second, the time between two drags of a finger.
let a_frame : Double = @ui.input_step_ms

///|
/// Moments the frame-rate test looks at, each mid-way through what it looks at: a finger down that long, let go that
/// long ago, a drag ended that long ago.
let held_ms : Double = 150.0

///|
let letting_go_ms : Double = 90.0

///|
let dragged_ms : Double = 120.0

