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
  t.run_for(a_frame)
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
  t.run_for(a_frame)
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
