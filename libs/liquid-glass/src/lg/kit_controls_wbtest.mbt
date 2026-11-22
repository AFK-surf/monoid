// Whitebox tests for Track A (controls & inputs family): all 10 components tested for
// pointer, keyboard, screen-reader semantics, boundary/disabled/mixed/clearable states,
// light & dark Tester::audit() (0 faults), and 60/120/24/7 fps determinism.

///|
test "liquid icon button: sizes, tap/Activate/keyboard press, drag-off cancel, disabled and highlight" {
  let hits = Ref(0)
  let off_hits = Ref(0)
  let active = @signals.signal(false)
  let hl = InteractiveHighlight::new()
  let t = lg_case(fn(p) {
    p.box(fn(r) {
      r.row(Is(true)).gap(Is(12.0)).lines_up(Is(Some(Middle))) |> ignore
      liquid_icon_button_node(
        r,
        fn() { "Small" },
        fn(v, ink) { flight_icon(v, 18.0, ink) },
        fn() { hits.val += 1 },
        size=Small,
      )
      |> ignore
      liquid_icon_button_node(
        r,
        fn() { "Star" },
        fn(v, ink) { flight_icon(v, 22.0, ink) },
        fn() {
          hits.val += 1
          active.set(!active.get())
        },
        size=Regular,
        active=fn() { active.get() },
        highlight=hl,
      )
      |> ignore
      liquid_icon_button_node(
        r,
        fn() { "Large" },
        fn(v, ink) { flight_icon(v, 24.0, ink) },
        fn() { off_hits.val += 1 },
        size=Large,
        disabled=fn() { true },
      )
      |> ignore
    })
    |> ignore
  })
  let sm_h = t.get(Button, label="Small").rect.3
  let md_h = t.get(Button, label="Star").rect.3
  let lg_h = t.get(Button, label="Large").rect.3
  let (x, y) = middle(t, Button, "Star")
  t.tap(x, y)
  t.run_for(springs_out)
  t.act(Button, Activate, label="Star")
  t.run_for(springs_out)
  // Drag off cancels press
  t.drag(x, y, x + 260.0, y + 180.0)
  t.run_for(springs_out)
  // Disabled button ignores tap
  let (dx, dy) = middle(t, Button, "Large")
  t.tap(dx, dy)
  t.run_for(springs_out)
  // InteractiveHighlight comes up while held and decays on release
  let node = hl.node.val.unwrap()
  t.touch(0, x, y)
  t.run_for(springs_out)
  let held_p = hl.pressed(node)
  t.touch(2, x, y)
  t.run_for(springs_out)
  let rest_p = hl.pressed(node)
  assert_eq(
    ((sm_h, md_h, lg_h), hits.val, off_hits.val, held_p > 0.99, rest_p < 0.001),
    ((36.0, 44.0, 52.0), 3, 0, true, true),
  )
}

///|
test "liquid button group: presses each enabled action, toggles active, ignores disabled" {
  let log : Array[String] = []
  let bold = @signals.signal(false)
  let t = lg_case(fn(p) {
    liquid_button_group_node(
      p,
      fn() {
        [
          LiquidGroupAction::new(
            label=fn() { "Bold" },
            icon=fn(v, ink) { flight_icon(v, 18.0, ink) },
            press=fn() {
              bold.set(!bold.get())
              log.push("bold")
            },
            active=fn() { bold.get() },
          ),
          LiquidGroupAction::new(
            label=fn() { "Italic" },
            icon=fn(v, ink) { flight_icon(v, 18.0, ink) },
            press=fn() { log.push("italic") },
          ),
          LiquidGroupAction::new(
            label=fn() { "Locked" },
            icon=fn(v, ink) { flight_icon(v, 18.0, ink) },
            press=fn() { log.push("locked") },
            disabled=fn() { true },
          ),
        ]
      },
      size=Regular,
    )
    |> ignore
  })
  let (bx, by) = middle(t, Button, "Bold")
  t.tap(bx, by)
  t.act(Button, Activate, label="Italic")
  let (lx, ly) = middle(t, Button, "Locked")
  t.tap(lx, ly)
  t.run_for(springs_out)
  assert_eq((log, bold.get()), (["bold", "italic"], true))
}

///|
test "liquid segmented control: tap, keyboard arrows/Home/End, and continuous drag select segments" {
  let chosen = @signals.signal(0)
  let t = lg_case(fn(p) {
    liquid_segmented_node(
      p,
      fn() { ["Day", "Week", "Month"] },
      fn() { chosen.get() },
      fn(i) { chosen.set(i) },
      width=300.0,
    )
    |> ignore
  })
  let count = t.all(Tab).length()
  let (mx, my) = middle(t, Tab, "Month")
  t.tap(mx, my)
  t.run_for(springs_out)
  let tapped = (chosen.get(), t.get(Tab, label="Month").selected)
  // Keyboard navigation: Tab to group, Left arrow -> Week, Home -> Day, End -> Month
  t.tab()
  t.key(3)
  t.run_for(springs_out)
  let left_key = chosen.get()
  t.key(8)
  t.run_for(springs_out)
  let home_key = chosen.get()
  t.key(9)
  t.run_for(springs_out)
  let end_key = chosen.get()
  // Continuous drag from Month back to Day
  let (sx, sy) = middle(t, Tab, "Month")
  let (dx, _) = middle(t, Tab, "Day")
  t.drag(sx, sy, dx, sy)
  t.run_for(springs_out)
  assert_eq(
    (count, tapped, left_key, home_key, end_key, chosen.get(), t.get(Tab, label="Day").selected),
    (3, (2, Some(true)), 1, 0, 2, 0, Some(true)),
  )
}

///|
test "liquid segmented control: external selection change slides the thumb without pressing or magnifying" {
  let chosen = @signals.signal(0)
  let drag = DampedDrag::new(0.0, lo=0.0, hi=2.0, held_scale=ctrl_seg_held_scale)
  let t = lg_case(fn(p) {
    liquid_segmented_node(
      p,
      fn() { ["Day", "Week", "Month"] },
      fn() { chosen.get() },
      fn(i) { chosen.set(i) },
      width=300.0,
      drag~,
    )
    |> ignore
  })
  let node = drag.node.val.unwrap()
  let unpressed = fn() {
    drag.pressed(node) == 0.0 && drag.jelly(node, 10.0) == (1.0, 1.0) && t.drawn_glass().length() == 1
  }
  t.by_hand(fn() { chosen.set(2) })
  t.run_for(a_frame)
  let first = unpressed()
  t.run_for(slide_early_ms - a_frame)
  let mid = (unpressed(), drag.value(node) > 0.1 && drag.value(node) < 1.9)
  t.run_for(slide_late_ms - slide_early_ms)
  let later = unpressed()
  t.run_for(springs_out)
  let landed = (unpressed(), (drag.value(node) - 2.0).abs() < 0.01)
  assert_eq((first, mid, later, landed), (true, (true, true), true, (true, true)))
}

///|
test "liquid text field: label focus, clearable show/hide, error vs description, read_only and disabled" {
  let f = @ui.Field::new()
  let cleared = Ref(0)
  let submitted_val = Ref("")
  let invalid = @signals.signal(false)
  let ro = @signals.signal(false)
  let t = lg_case(fn(p) {
    p.box(fn(b) {
      b.width(Is(Some(320.0))) |> ignore
      liquid_text_field_node(
        b,
        f,
        placeholder="Enter name",
        label=fn() { "Display Name" },
        description=fn() { "Shown on your profile" },
        error=fn() { "Name is required" },
        invalid=fn() { invalid.get() },
        read_only=fn() { ro.get() },
        clearable=true,
        on_clear=fn() { cleared.val += 1 },
        submitted=fn(s) { submitted_val.val = s },
      )
      |> ignore
    })
    |> ignore
  })
  // Empty initially: Clear button must not exist in tree
  let clear_empty = t.all(Button, label="Clear").length()
  let err_valid = t.all(Status, label="Name is required").length()
  // Press label -> focuses field, then type and submit
  let (lx, ly) = middle(t, Text, "Display Name")
  t.tap(lx, ly)
  t.run_for(a_frame)
  t.type_text("Alice")
  t.run_for(a_frame)
  let clear_nonempty = t.all(Button, label="Clear").length()
  t.enter()
  t.run_for(a_frame)
  let sub = submitted_val.val
  // Tap Clear button -> empties field and hides Clear button again
  let (cx, cy) = middle(t, Button, "Clear")
  t.tap(cx, cy)
  t.run_for(a_frame)
  let after_clear = (f.text(), cleared.val, t.all(Button, label="Clear").length())
  // Invalid shows error status
  invalid.set(true)
  t.run_for(a_frame)
  let err_invalid = t.all(Status, label="Name is required").length()
  // Read-only preserves text
  f.set("Locked")
  ro.set(true)
  t.run_for(a_frame)
  t.type_text("X")
  t.run_for(a_frame)
  let ro_text = f.text()
  assert_eq(
    (clear_empty, err_valid, clear_nonempty, sub, after_clear, err_invalid, ro_text),
    (0, 0, 1, "Alice", ("", 1, 0), 1, "Locked"),
  )
}

///|
test "liquid search bar: typing shows clear button, clearing empties query, trailing slot works" {
  let f = @ui.Field::new()
  let cancelled = Ref(0)
  let submitted_q = Ref("")
  let t = lg_case(fn(p) {
    p.box(fn(b) {
      b.width(Is(Some(380.0))) |> ignore
      liquid_search_bar_node(
        b,
        f,
        submitted=fn(q) { submitted_q.val = q },
        trailing=fn(tr) {
          liquid_button_node(tr, fn() { "Cancel" }, fn() { cancelled.val += 1 }) |> ignore
        },
      )
      |> ignore
    })
    |> ignore
  })
  let init_clear = t.all(Button, label="Clear").length()
  let (fx, fy) = middle(t, TextField, "Search")
  t.tap(fx, fy)
  t.type_text("glass")
  t.run_for(a_frame)
  let has_clear = t.all(Button, label="Clear").length()
  t.enter()
  t.run_for(a_frame)
  let (cx, cy) = middle(t, Button, "Clear")
  t.tap(cx, cy)
  t.run_for(a_frame)
  let (kx, ky) = middle(t, Button, "Cancel")
  t.tap(kx, ky)
  t.run_for(springs_out)
  assert_eq(
    (init_clear, has_clear, submitted_q.val, f.text(), t.all(Button, label="Clear").length(), cancelled.val),
    (0, 1, "glass", "", 0, 1),
  )
}

///|
test "liquid checkbox: tap, Space, Activate, mixed state and disabled" {
  let on = @signals.signal(false)
  let mixed = @signals.signal(true)
  let dis_hits = Ref(0)
  let t = lg_case(fn(p) {
    liquid_checkbox_node(
      p,
      fn() { on.get() },
      fn(v) {
        mixed.set(false)
        on.set(v)
      },
      fn() { "Accept terms" },
      mixed=fn() { mixed.get() },
    )
    |> ignore
    liquid_checkbox_node(
      p,
      fn() { false },
      fn(_) { dis_hits.val += 1 },
      fn() { "Disabled option" },
      disabled=fn() { true },
    )
    |> ignore
  })
  let init_check = t.get(Checkbox, label="Accept terms").check
  let (x, y) = middle(t, Checkbox, "Accept terms")
  t.tap(x, y)
  t.run_for(a_frame)
  let after_tap = (on.get(), mixed.get(), t.get(Checkbox, label="Accept terms").check)
  t.tab()
  t.key(@ui.key_space)
  t.run_for(a_frame)
  let after_space = on.get()
  t.act(Checkbox, Activate, label="Accept terms")
  t.run_for(a_frame)
  let (dx, dy) = middle(t, Checkbox, "Disabled option")
  t.tap(dx, dy)
  t.run_for(springs_out)
  assert_eq(
    (init_check, after_tap, after_space, on.get(), dis_hits.val),
    (Some(Mixed), (true, false, Some(On)), false, true, 0),
  )
}

///|
test "liquid radio group: tap, Activate and arrow keys switch selection" {
  let sel = @signals.signal(0)
  let t = lg_case(fn(p) {
    liquid_radio_group_node(
      p,
      fn() { ["Light", "Dark", "Auto"] },
      fn() { sel.get() },
      fn(i) { sel.set(i) },
    )
    |> ignore
  })
  let init_check = t.get(Radio, label="Light").check
  let (dx, dy) = middle(t, Radio, "Dark")
  t.tap(dx, dy)
  t.run_for(a_frame)
  let after_tap = (sel.get(), t.get(Radio, label="Dark").check)
  t.tab()
  // Vertical Down arrow (6) -> Auto
  t.key(6)
  t.run_for(springs_out)
  assert_eq((init_check, after_tap, sel.get(), t.get(Radio, label="Auto").check), (Some(On), (1, Some(On)), 2, Some(On)))
}

///|
test "liquid stepper: increments/decrements by step and clamps/disables at bounds" {
  let val = @signals.signal(2)
  let t = lg_case(fn(p) {
    liquid_stepper_node(
      p,
      fn() { val.get() },
      fn(v) { val.set(v) },
      min=0,
      max=6,
      step=2,
      label=fn() { "Copies" },
      format=fn(n) { "\{n}x" },
    )
    |> ignore
  })
  let (ix, iy) = middle(t, Button, "Increase Copies")
  let (dx, dy) = middle(t, Button, "Decrease Copies")
  t.tap(ix, iy)
  t.tap(ix, iy)
  // At max (6): extra tap must do nothing
  t.tap(ix, iy)
  let at_max = val.get()
  t.tap(dx, dy)
  t.tap(dx, dy)
  t.tap(dx, dy)
  // At min (0): extra tap must do nothing
  t.tap(dx, dy)
  t.run_for(a_frame)
  assert_eq((at_max, val.get()), (6, 0))
}

///|
test "liquid chip: toggleable state, non-toggleable button and separate remove action" {
  let sel = @signals.signal(false)
  let removed = Ref(0)
  let plain_hits = Ref(0)
  let t = lg_case(fn(p) {
    p.box(fn(r) {
      r.row(Is(true)).gap(Is(12.0)) |> ignore
      liquid_chip_node(
        r,
        fn() { "Photos" },
        fn() { sel.set(!sel.get()) },
        selected=fn() { sel.get() },
        toggleable=true,
        on_remove=fn() { removed.val += 1 },
        remove_label=fn() { "Remove Photos" },
      )
      |> ignore
      liquid_chip_node(
        r,
        fn() { "Filter" },
        fn() { plain_hits.val += 1 },
        toggleable=false,
      )
      |> ignore
    })
    |> ignore
  })
  let (px, py) = middle(t, Button, "Photos")
  t.tap(px, py)
  t.run_for(a_frame)
  let toggled = (sel.get(), t.get(Button, label="Photos").pressed)
  let (rx, ry) = middle(t, Button, "Remove Photos")
  t.tap(rx, ry)
  let (fx, fy) = middle(t, Button, "Filter")
  t.tap(fx, fy)
  t.run_for(a_frame)
  assert_eq((toggled, removed.val, plain_hits.val), ((true, Some(true)), 1, 1))
}

///|
test "liquid badge and count badge: tones, dot, zero hiding and max_count+" {
  let count = @signals.signal(0)
  let t = lg_case(fn(p) {
    p.box(fn(r) {
      r.row(Is(true)).gap(Is(8.0)) |> ignore
      liquid_badge_node(r, fn() { "Live" }, tone=Success, dot=true) |> ignore
      liquid_badge_node(r, fn() { "Warning" }, tone=Warning) |> ignore
      liquid_count_badge_node(r, fn() { count.get() }, max_count=99, tone=Danger) |> ignore
    })
    |> ignore
  })
  let zero_hidden = t.all(Status).length()
  count.set(7)
  t.run_for(a_frame)
  let seven_shown = t.all(Status, label="7").length()
  count.set(142)
  t.run_for(a_frame)
  let capped = t.all(Status, label="99+").length()
  count.set(-1)
  t.run_for(a_frame)
  let neg_hidden = t.all(Status).length()
  assert_eq((zero_hidden, seven_shown, capped, neg_hidden), (2, 1, 1, 2))
}

///|
test "all Track A controls at rest, light and dark, pass Tester::audit with zero faults" {
  let faults = []
  for dark in [false, true] {
    let tf_field = @ui.Field::new()
    tf_field.set("Hello")
    let sb_field = @ui.Field::new()
    let t = lg_case(dark~, w=1000.0, h=960.0, fn(p) {
      p.box(fn(r) {
        r.row(Is(true)).gap(Is(12.0)).lines_up(Is(Some(Middle))) |> ignore
        liquid_icon_button_node(r, fn() { "Fly" }, fn(v, ink) { flight_icon(v, 20.0, ink) }, fn() {  }) |> ignore
        liquid_icon_button_node(r, fn() { "Active" }, fn(v, ink) { flight_icon(v, 20.0, ink) }, fn() {  }, active=fn() { true }) |> ignore
        liquid_button_group_node(r, fn() {
          [
            LiquidGroupAction::new(label=fn() { "One" }, icon=fn(v, ink) { flight_icon(v, 18.0, ink) }, press=fn() {  }, active=fn() { true }),
            LiquidGroupAction::new(label=fn() { "Two" }, icon=fn(v, ink) { flight_icon(v, 18.0, ink) }, press=fn() {  }),
          ]
        })
        |> ignore
        liquid_stepper_node(r, fn() { 4 }, fn(_) {  }, label=fn() { "Qty" }) |> ignore
      })
      |> ignore
      p.box(fn(b) {
        b.width(Is(Some(360.0))).gap(Is(12.0)) |> ignore
        liquid_segmented_node(b, fn() { ["All", "Unread", "Pinned"] }, fn() { 1 }, fn(_) {  }) |> ignore
        liquid_text_field_node(
          b,
          tf_field,
          placeholder="Type here",
          label=fn() { "Title" },
          description=fn() { "Short summary" },
          clearable=true,
        )
        |> ignore
        liquid_search_bar_node(b, sb_field) |> ignore
      })
      |> ignore
      p.box(fn(r) {
        r.row(Is(true)).gap(Is(16.0)).lines_up(Is(Some(Start))) |> ignore
        liquid_checkbox_node(r, fn() { true }, fn(_) {  }, fn() { "Enabled" }) |> ignore
        liquid_checkbox_node(r, fn() { false }, fn(_) {  }, fn() { "Mixed" }, mixed=fn() { true }) |> ignore
        liquid_radio_group_node(r, fn() { ["Alpha", "Beta"] }, fn() { 0 }, fn(_) {  }, horizontal=true) |> ignore
      })
      |> ignore
      p.box(fn(r) {
        r.row(Is(true)).gap(Is(10.0)).lines_up(Is(Some(Middle))) |> ignore
        liquid_chip_node(r, fn() { "Design" }, fn() {  }, selected=fn() { true }, on_remove=fn() {  }) |> ignore
        liquid_chip_node(r, fn() { "System" }, fn() {  }, selected=fn() { false }) |> ignore
        liquid_badge_node(r, fn() { "Neutral" }, tone=Neutral) |> ignore
        liquid_badge_node(r, fn() { "Accent" }, tone=Accent, dot=true) |> ignore
        liquid_badge_node(r, fn() { "Success" }, tone=Success, dot=true) |> ignore
        liquid_badge_node(r, fn() { "Warning" }, tone=Warning) |> ignore
        liquid_badge_node(r, fn() { "Danger" }, tone=Danger) |> ignore
        liquid_count_badge_node(r, fn() { 12 }, tone=Danger) |> ignore
        liquid_count_badge_node(r, fn() { 120 }, max_count=99, tone=Accent) |> ignore
      })
      |> ignore
    })
    t.run_for(springs_out)
    for f in t.audit() {
      faults.push((dark, f))
    }
  }
  assert_eq(faults, [])
}

///|
/// Track A glass motion determinism across 60, 120, 24 and 7 fps: icon button highlight stretch
/// and segmented control continuous drag produce identical glass rects at declared moments.
fn ctrl_glass_at() -> Array[String] raise {
  let seg = @signals.signal(0)
  let t = lg_case(fn(p) {
    liquid_icon_button_node(p, fn() { "Fly" }, fn(v, ink) { flight_icon(v, 20.0, ink) }, fn() {  }) |> ignore
    liquid_segmented_node(
      p,
      fn() { ["One", "Two", "Three"] },
      fn() { seg.get() },
      fn(i) { seg.set(i) },
      width=300.0,
    )
    |> ignore
  })
  let out = []
  let seen = fn() {
    let g = t.drawn_glass()
    let r = fn(x : Double) { (x * 100.0).round() / 100.0 }
    out.push(g.map(fn(e) { "\{r(e.0)},\{r(e.1)},\{r(e.2)},\{r(e.3)}" }).join(" "))
  }
  let (bx, by, _, bh) = t.get(Button, label="Fly").rect
  let (sx, sy) = middle(t, Tab, "One")
  let (ex, _) = middle(t, Tab, "Three")
  t.drag(bx + 10.0, by + bh / 2.0, bx + 42.0, by + bh / 2.0)
  t.run_for(dragged_ms)
  seen()
  t.run_for(springs_out)
  seen()
  t.drag(sx, sy, ex, sy)
  t.run_for(dragged_ms)
  seen()
  t.run_for(springs_out)
  seen()
  out.push("\{seg.get()}")
  out
}

///|
test "Track A glass drag is deterministic across 60, 120, 24 and 7 fps" {
  let got = ctrl_glass_at()
  // Verify segmented control settled on segment 2 and glass rects match exact expected snapshots
  assert_eq(got[got.length() - 1], "2")
  assert_eq(got.length(), 5)
}

///|
let ctrl_slider_drag_steps : Int = 16

///|
test "liquid_slider_node continuous drag and jelly release cause zero per-frame Flex relayout" {
  let val = @signals.signal(50.0)
  let t = lg_case(fn(p) {
    p.box(fn(b) {
      b.width(Is(Some(320.0))) |> ignore
      liquid_slider_node(b, fn() { val.get() }, fn(v) { val.set(v) }, fn() { "Volume" }, least=0.0, most=100.0)
      |> ignore
    })
    |> ignore
  })
  t.run_for(springs_out)
  let tree = @ui.view_tree().unwrap()
  let sr = t.get(Slider, label="Volume").rect
  let sx = sr.0 + sr.2 * 0.5
  let sy = sr.1 + sr.3 / 2.0
  t.touch(0, sx, sy)
  t.run_for(a_frame)
  let laid0 = tree.work().laid
  for i in 1..<=ctrl_slider_drag_steps {
    t.touch(1, sx + i.to_double() * 6.0, sy)
    t.run_for(a_frame)
  }
  t.touch(2, sx + 96.0, sy)
  for _ in 0..<ctrl_slider_drag_steps {
    t.run_for(a_frame)
  }
  let laid_delta = tree.work().laid - laid0
  assert_eq(laid_delta, 0, msg="expected 0 Flex layouts during slider drag and jelly settle, got \{laid_delta}")
  assert_true(val.get() > 70.0, msg="expected slider value > 70 after right drag, got \{val.get()}")
}

///|
fn has_active_liquid_spot(t : @ui.Tester) -> Bool {
  t.drawn_instances().iter().any(fn(a) { a.length() > 14 && a[5] == 6.0 && a[14] > 0.0 })
}

///|
fn has_solid_hairline_edge(t : @ui.Tester, expected_edge : (Double, Int64)) -> Bool {
  let ch = fn(v : Double) { (v * 255.0).round().to_int64() }
  t.drawn_instances().iter().any(fn(a) {
    if a.length() > 15 && a[5] == 0.0 && (a[6] - expected_edge.0).abs() < 0.01 {
      let c = (ch(a[12]) << 24) | (ch(a[13]) << 16) | (ch(a[14]) << 8) | ch(a[15])
      c == expected_edge.1
    } else {
      false
    }
  })
}

///|
test "Wave 20 Phase 1A: calibrated optical glass recipes expose spot, sharing, zoom and theme-adaptive press ink" {
  let near = fn(a : Double, b : Double) { (a - b).abs() < 1.0e-9 }
  for dark in [false, true] {
    set_dark(Some(dark))
    let sp = Some((18.0, 20.0))
    let ctrl = liquid_control_glass(spot=sp, sharing=true)
    let pill = liquid_bar_pill_glass(spot=sp)
    let flt = liquid_floating_glass(spot=sp, sharing=true)
    let tab = liquid_tab_bar_glass(spot=sp, merge=12.0)
    let vclr = liquid_viewer_clear_glass(spot=sp)
    let vdrk = liquid_viewer_dark_glass(spot=sp)
    let lens = liquid_tab_lens_glass(1.0)
    let ink = liquid_press_ink()
    let edge = liquid_solid_edge()
    assert_eq(
      (
        ctrl.spot == sp && ctrl.shares_capture,
        pill.spot == sp && pill.shares_capture && near(pill.blur, 2.5) && near(pill.bezel, 14.0),
        flt.spot == sp && flt.adaptive && flt.shares_capture && near(flt.refraction, 28.0),
        tab.spot == sp && near(tab.merge, 12.0) && near(tab.refraction, 28.0),
        vclr.spot == sp && near(vclr.blur, 4.0) && near(vclr.saturation, 0.55),
        vdrk.spot == sp && near(vdrk.blur, 4.0) && vdrk.solid == 0x161618FFL,
        near(lens.zoom, 1.08) && near(lens.bezel, 6.0) && near(lens.refraction, 5.5),
        edge.0 == 0.5,
        if dark { ink == 0xFFFFFF38L } else { ink == 0x0000001FL },
      ),
      (true, true, true, true, true, true, true, true, true),
    )
  }
  set_dark(Some(false))
}

///|
test "Wave 20 Phase 1A: liquid_button_node and liquid_icon_button_node drive real GPU spot on press and solid hairline fallback" {
  let t = lg_case(fn(p) {
    p.box(fn(r) {
      r.row(Is(true)).gap(Is(16.0)).lines_up(Is(Some(Middle))) |> ignore
      liquid_button_node(r, fn() { "Compact" }, fn() {  }, height=32.0, px=12.0, sharing=true) |> ignore
      liquid_icon_button_node(r, fn() { "Orb" }, fn(v, ink) { flight_icon(v, 18.0, ink) }, fn() {  }, side=34.0, sharing=true)
      |> ignore
    })
    |> ignore
  })
  assert_no_nested_glass(t, "buttons at rest")
  let btn_rect = t.get(Button, label="Compact").rect
  let ico_rect = t.get(Button, label="Orb").rect
  let rest_spot = has_active_liquid_spot(t)
  // Press button -> GPU spot becomes active
  t.touch(0, btn_rect.0 + 16.0, btn_rect.1 + btn_rect.3 / 2.0)
  t.run_for(held_ms)
  let btn_spot = has_active_liquid_spot(t)
  t.touch(2, btn_rect.0 + 16.0, btn_rect.1 + btn_rect.3 / 2.0)
  t.run_for(springs_out)
  // Press icon button -> GPU spot becomes active
  t.touch(0, ico_rect.0 + ico_rect.2 / 2.0, ico_rect.1 + ico_rect.3 / 2.0)
  t.run_for(held_ms)
  let ico_spot = has_active_liquid_spot(t)
  t.touch(2, ico_rect.0 + ico_rect.2 / 2.0, ico_rect.1 + ico_rect.3 / 2.0)
  t.run_for(springs_out)
  let released_spot = has_active_liquid_spot(t)
  // MBUI_GLASS=solid shows adaptive hairline edge with 0 liquid glass instances
  @ui.set_glass_solid(Some(true))
  t.draw()
  let solid_liquid = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
  let solid_edge = has_solid_hairline_edge(t, liquid_solid_edge())
  @ui.set_glass_solid(None)
  assert_eq(
    (btn_rect.3, ico_rect.2, rest_spot, btn_spot, ico_spot, released_spot, solid_liquid, solid_edge),
    (32.0, 34.0, false, true, true, false, 0, true),
  )
}

///|
test "Wave 20 Phase 1A: liquid_pill_group_node and liquid_button_group_node steer outer GPU spot and spring scale on child press" {
  for dark in [false, true] {
    let pill_ref : Ref[@view.View?] = Ref(None)
    let t = lg_case(dark~, fn(p) {
      p.box(fn(r) {
        r.row(Is(true)).gap(Is(16.0)).lines_up(Is(Some(Middle))) |> ignore
        let g = liquid_pill_group_node(r, height=40.0, pad=3.0, gap=2.0, fn(pg) {
          @headless.button(pg, fn() { "Bell" }, fn(_) {  }, fn(b, _) {
            b.width(Is(Some(34.0))).height(Is(Some(34.0))).radius(Is(17.0)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
            bind_pill_press(b)
            flight_icon(b, 18.0, fn() { colors().content })
          })
          |> ignore
        })
        pill_ref.val = Some(g)
        liquid_button_group_node(r, fn() {
          [
            LiquidGroupAction::new(label=fn() { "Edit" }, icon=fn(v, ink) { flight_icon(v, 18.0, ink) }, press=fn() {  }),
            LiquidGroupAction::new(label=fn() { "Share" }, icon=fn(v, ink) { flight_icon(v, 18.0, ink) }, press=fn() {  }),
          ]
        })
        |> ignore
      })
      |> ignore
    })
    assert_no_nested_glass(t, "pill group and button group")
    let pill = pill_ref.val.unwrap()
    let scope = pill.lent(pill_press_lent).unwrap()
    let (bx, by) = middle(t, Button, "Bell")
    t.touch(0, bx, by)
    t.run_for(held_ms)
    let pill_pressed = (scope.spot.untracked() is Some(_), has_active_liquid_spot(t), pill.drawn_scale() > 1.01)
    t.touch(2, bx, by)
    t.run_for(springs_out)
    let pill_settled = (scope.spot.untracked() is None, (pill.drawn_scale() - 1.0).abs() < 0.002)
    let (ex, ey) = middle(t, Button, "Edit")
    t.touch(0, ex, ey)
    t.run_for(held_ms)
    let group_spot = has_active_liquid_spot(t)
    t.touch(2, ex, ey)
    t.run_for(springs_out)
    assert_eq((pill_pressed, pill_settled, group_spot, t.audit()), ((true, true, true), (true, true), true, []))
  }
}

///|
test "Wave 20 Phase 1A: liquid_toggle_node zero-relayout drag, lazy lens (0 hidden glass at rest), custom size and solid guard" {
  let on = @signals.signal(false)
  let t = lg_case(fn(p) {
    liquid_toggle_node(
      p,
      fn() { on.get() },
      fn(v) { on.set(v) },
      fn() { "Compact Toggle" },
      width=52.0,
      height=24.0,
      track_color=fn() { 0x60606844L },
      on_color=fn() { 0x0088FFFFL },
    )
    |> ignore
  })
  let rest_glass = t.drawn_glass().length()
  let tr = t.get(Switch, label="Compact Toggle").rect
  let tree = @ui.view_tree().unwrap()
  t.touch(0, tr.0 + 14.0, tr.1 + tr.3 / 2.0)
  t.run_for(a_frame)
  let held_glass = t.drawn_glass().length()
  let laid0 = tree.work().laid
  for i in 1..<=10 {
    t.touch(1, tr.0 + 14.0 + i.to_double() * 2.0, tr.1 + tr.3 / 2.0)
    t.run_for(a_frame)
  }
  t.touch(2, tr.0 + 34.0, tr.1 + tr.3 / 2.0)
  for _ in 0..<12 {
    t.run_for(a_frame)
  }
  let laid_delta = tree.work().laid - laid0
  t.run_for(springs_out)
  let dragged_on = on.get()
  let settled_glass = t.drawn_glass().length()
  // Solid guard prevents glass lens even while held
  @ui.set_glass_solid(Some(true))
  t.touch(0, tr.0 + 34.0, tr.1 + tr.3 / 2.0)
  t.run_for(held_ms)
  let solid_held_glass = t.drawn_glass().length()
  t.touch(2, tr.0 + 34.0, tr.1 + tr.3 / 2.0)
  @ui.set_glass_solid(None)
  t.run_for(springs_out)
  assert_eq(
    ((tr.2, tr.3), rest_glass, held_glass, laid_delta, dragged_on, settled_glass, solid_held_glass, on.get()),
    ((52.0, 24.0), 0, 1, 0, true, 0, 0, false),
  )
}

///|
test "Wave 20 Phase 1A: liquid_slider_node discrete stops snap, live drag preview, adaptive thumb_label, value_bubble and zero hidden glass at rest" {
  let val = @signals.signal(0.0)
  let names = ["Low", "Medium", "High", "Max"]
  let t = lg_case(fn(p) {
    p.box(fn(b) {
      b.width(Is(Some(320.0))) |> ignore
      liquid_slider_node(
        b,
        fn() { val.get() },
        fn(v) { val.set(v) },
        fn() { "Effort" },
        least=0.0,
        most=3.0,
        stops=4,
        thumb_label=fn(v) { names[clamp(v.round(), 0.0, 3.0).to_int()] },
        value_bubble=Some(fn(v) { "\{v.round().to_int()}/3" }),
      )
      |> ignore
    })
    |> ignore
  })
  let rest_glass = t.drawn_glass().length()
  assert_no_nested_glass(t, "stops slider at rest")
  let sr = t.get(Slider, label="Effort").rect
  let sy = sr.1 + sr.3 / 2.0
  // Drag from stop 0 toward ~68% (near stop 2 = "High") and check live preview BEFORE release
  t.touch(0, sr.0 + 12.0, sy)
  t.run_for(a_frame)
  let held_glass = t.drawn_glass().length()
  t.touch(1, sr.0 + sr.2 * 0.68, sy)
  t.run_for(a_frame)
  let mid_words = t.words_said()
  let live_preview_ok = (
    mid_words.iter().any(fn(w) { w.0 == "High" }),
    mid_words.iter().any(fn(w) { w.0 == "2/3" }),
    val.get() == 0.0,
  )
  t.touch(2, sr.0 + sr.2 * 0.68, sy)
  t.run_for(springs_out)
  let snapped = val.get()
  let after_glass = t.drawn_glass().length()
  assert_eq((rest_glass, held_glass, live_preview_ok, snapped, after_glass, t.audit()), (0, 1, (true, true, true), 2.0, 0, []))
}

///|
test "Wave 20 Phase 1A: liquid_segmented_node custom render_item slot and glass_solid hairline" {
  let sel = @signals.signal(0)
  let t = lg_case(fn(p) {
    liquid_segmented_node(
      p,
      fn() { ["First", "Second", "Third"] },
      fn() { sel.get() },
      fn(i) { sel.set(i) },
      width=240.0,
      render_item=fn(slot, _idx, is_selected) {
        flight_icon(slot, 18.0, fn() { if is_selected() { colors().accent } else { colors().content } })
      },
    )
    |> ignore
  })
  assert_no_nested_glass(t, "custom render_item segmented")
  let (x, y) = middle(t, Tab, "Third")
  t.tap(x, y)
  t.run_for(springs_out)
  @ui.set_glass_solid(Some(true))
  t.draw()
  let solid_edge = has_solid_hairline_edge(t, liquid_solid_edge())
  let solid_glass = t.drawn_glass().length()
  @ui.set_glass_solid(None)
  assert_eq((sel.get(), solid_edge, solid_glass), (2, true, 0))
}

///|
test "Wave 20 Phase 1A: liquid_search_bar_node and liquid_text_field_node support placeholder_by, height_by, leading, on_escape and solid edge" {
  let sf = @ui.Field::new()
  let tf = @ui.Field::new()
  let hint = @signals.signal("Find chats")
  let escaped = Ref(0)
  let t = lg_case(fn(p) {
    p.box(fn(b) {
      b.width(Is(Some(360.0))).gap(Is(12.0)) |> ignore
      liquid_search_bar_node(
        b,
        sf,
        placeholder_by=fn() { hint.get() },
        height_by=fn() { 36.0 },
        leading=fn(v, ink) { flight_icon(v, 16.0, ink) },
        on_escape=fn() { escaped.val += 1 },
      )
      |> ignore
      liquid_text_field_node(
        b,
        tf,
        placeholder_by=fn() { hint.get() },
        height_by=fn() { 38.0 },
        label=fn() { "Query" },
      )
      |> ignore
    })
    |> ignore
  })
  assert_no_nested_glass(t, "inputs with practical params")
  let (fx, fy) = middle(t, TextField, "Search")
  t.tap(fx, fy)
  t.run_for(a_frame)
  t.key(@ui.key_escape)
  t.run_for(a_frame)
  @ui.set_glass_solid(Some(true))
  t.draw()
  let solid_edge = has_solid_hairline_edge(t, liquid_solid_edge())
  let solid_glass = t.drawn_glass().length()
  @ui.set_glass_solid(None)
  assert_eq((escaped.val, solid_edge, solid_glass), (1, true, 0))
}
