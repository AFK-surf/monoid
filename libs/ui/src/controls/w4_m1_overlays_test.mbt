// Wave 4 Stage 2 (Track W4-M1) regression tests:
// 1. Unified `@headless.overlays_open(tree)` stack registration across all 8 migrated controls:
//    `confirm_node`, `panel_node`, `beside_panel_node`, `pick_node`, `sheet_node`,
//    `drawer_node`, `action_sheet_node`, `menu_node`, plus multi-layer Escape ordering.
// 2. `drawer_node` via `@headless.drawer`: rubber-band over-pull, reverse-fling protection,
//    velocity-continuous fling dismiss, and Escape / outside-press dismissal.
// 3. `menu_node` & `action_sheet_node` via `@headless.overlay` + `@headless.menu`:
//    keyboard roving navigation, wrap-around, disabled/heading skipping, typeahead, and `keep_field`.

///|
fn w4_overlays_open() -> Int {
  @headless.overlays_open(@ui.view_tree().unwrap())
}

///|
fn w4_focused_label(t : @ui.Tester) -> String {
  t.focused().map(fn(s) { s.label }).unwrap_or("")
}

///|
fn w4_item(
  label : String,
  disabled? : Bool = false,
  heading? : Bool = false,
  select? : () -> Unit = fn() {  },
) -> @controls.MenuItem {
  {
    label,
    icon: "",
    danger: false,
    disabled,
    chosen: None,
    checkbox: false,
    heading,
    further: false,
    select,
  }
}

///|
fn w4_tester(w : Double, h : Double, make : (@view.View) -> Unit) -> @ui.Tester {
  @controls.presenters_reset()
  @controls.set_words(fn(key, _) { key })
  @controls.set_dark(Some(false))
  @ui.set_glass_solid(None)
  let t = @ui.Tester::new(fn(_) {  }, w~, h~, dark=false, platform=0)
  @ui.set_view_app(
    fn(root) {
      @ui.set_tree_theme(@controls.ui_theme_now)
      make(root)
    },
    theme=@controls.ui_theme_now,
  )
  t.draw()
  t
}

///|
test "W4-M1: all 8 migrated controls register in @headless.overlays_open and unwind cleanly" {
  // 1. confirm_node, beside_panel_node, pick_node, drawer_node, action_sheet_node, menu_node on wide screen
  let confirm_open = @signals.signal(false)
  let beside_open = @signals.signal(false)
  let pick_open = @signals.signal(false)
  let drawer_open = @signals.signal(false)
  let sheet_act_open = @signals.signal(false)
  let menu_open = @signals.signal(false)
  let pick_field = @ui.Field::new()
  let anchor_ref : Ref[@view.View?] = Ref(None)
  let t = w4_tester(900.0, 640.0, fn(root) {
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((32.0, 32.0, 32.0, 32.0))) |> ignore
      let btn = @controls.button_node(page, fn() { "Trigger" }, fn() {  })
      anchor_ref.val = Some(btn)
      @controls.confirm_node(
        page,
        fn() { confirm_open.get() },
        fn() { "Confirm Title" },
        fn() { "Are you sure?" },
        fn() { "Proceed" },
        false,
        fn() { confirm_open.set(false) },
        fn() { confirm_open.set(false) },
      )
      @controls.beside_panel_node(
        page,
        fn() { beside_open.get() },
        fn(_) { anchor_ref.val.unwrap() },
        240.0,
        fn() { "Beside Panel" },
        fn(b) {
          @controls.button_node(b, fn() { "Inside Beside" }, fn() {  }) |> ignore
        },
        fn() { beside_open.set(false) },
      )
      @controls.pick_node(
        page,
        fn() { pick_open.get() },
        fn(_) { anchor_ref.val.unwrap() },
        "Pick One",
        [@controls.choice("a", "Alpha"), @controls.choice("b", "Beta")],
        "a",
        pick_field,
        Start,
        6.0,
        fn(_) { pick_open.set(false) },
        fn() { pick_open.set(false) },
      )
      @controls.drawer_node(
        page,
        fn() { drawer_open.get() },
        fn() { "Side Drawer" },
        fn() { drawer_open.set(false) },
        fn(b) {
          @controls.button_node(b, fn() { "Drawer Action" }, fn() {  }) |> ignore
        },
      )
      @controls.action_sheet_node(
        page,
        fn() { sheet_act_open.get() },
        fn(_) { anchor_ref.val.unwrap() },
        fn() { "Quick Actions" },
        fn() { "Choose one" },
        fn() { [@controls.sheet_action("Run", fn() {  })] },
        fn() { sheet_act_open.set(false) },
      )
      @controls.menu_node(
        page,
        fn() { menu_open.get() },
        fn(_) { anchor_ref.val.unwrap() },
        fn() { [Some(w4_item("Copy")), Some(w4_item("Paste"))] },
        "Edit",
        Start,
        6.0,
        false,
        false,
        fn(_) { menu_open.set(false) },
        fn() { menu_open.set(false) },
      )
    })
    |> ignore
    @controls.presented_nodes(root)
  })
  let settle = @ui.move_most_ms * 2.0
  assert_eq(w4_overlays_open(), 0)

  // confirm_node
  confirm_open.set(true)
  t.run_for(settle)
  assert_eq(w4_overlays_open(), 1)
  t.key(@ui.key_escape)
  t.run_for(settle)
  assert_eq((confirm_open.untracked(), w4_overlays_open()), (false, 0))

  // panel_node (via panel_nodes anchored on wide screen)
  @controls.panel_nodes(
    "Anchored Panel",
    fn(b, _) { @controls.button_node(b, fn() { "Panel Btn" }, fn() {  }) |> ignore },
    from=At(40.0, 40.0, 80.0, 32.0),
  )
  t.run_for(settle)
  assert_eq(w4_overlays_open(), 1)
  t.key(@ui.key_escape)
  t.run_for(settle)
  assert_eq(w4_overlays_open(), 0)

  // beside_panel_node
  beside_open.set(true)
  t.run_for(settle)
  assert_eq(w4_overlays_open(), 1)
  t.key(@ui.key_escape)
  t.run_for(settle)
  assert_eq((beside_open.untracked(), w4_overlays_open()), (false, 0))

  // pick_node (Escape clears search first, then closes)
  pick_field.set("Al")
  pick_open.set(true)
  t.run_for(settle)
  assert_eq(w4_overlays_open(), 1)
  t.key(@ui.key_escape)
  assert_eq((pick_field.text(), pick_open.untracked()), ("", true))
  t.key(@ui.key_escape)
  t.run_for(settle)
  assert_eq((pick_open.untracked(), w4_overlays_open()), (false, 0))

  // drawer_node
  drawer_open.set(true)
  t.run_for(settle)
  assert_eq(w4_overlays_open(), 1)
  t.key(@ui.key_escape)
  t.run_for(settle)
  assert_eq((drawer_open.untracked(), w4_overlays_open()), (false, 0))

  // action_sheet_node
  sheet_act_open.set(true)
  t.run_for(settle)
  assert_eq(w4_overlays_open(), 1)
  t.key(@ui.key_escape)
  t.run_for(settle)
  assert_eq((sheet_act_open.untracked(), w4_overlays_open()), (false, 0))

  // menu_node
  menu_open.set(true)
  t.run_for(settle)
  assert_eq(w4_overlays_open(), 1)
  t.key(@ui.key_escape)
  t.run_for(settle)
  assert_eq((menu_open.untracked(), w4_overlays_open()), (false, 0))

  // Layered stack: drawer_node + confirm_node -> 1st Escape closes confirm only, 2nd closes drawer
  drawer_open.set(true)
  t.run_for(settle)
  confirm_open.set(true)
  t.run_for(settle)
  assert_eq(w4_overlays_open(), 2)
  t.key(@ui.key_escape)
  t.run_for(settle)
  assert_eq((confirm_open.untracked(), drawer_open.untracked(), w4_overlays_open()), (false, true, 1))
  t.key(@ui.key_escape)
  t.run_for(settle)
  assert_eq((drawer_open.untracked(), w4_overlays_open()), (false, 0))

  // 2. sheet_node (via panel_nodes on narrow screen)
  let ts = w4_tester(390.0, 844.0, fn(root) {
    root.box(fn(page) {
      page.grow(Is(1.0)) |> ignore
    })
    |> ignore
    @controls.presented_nodes(root)
  })
  assert_eq(w4_overlays_open(), 0)
  @controls.panel_nodes(
    "Mobile Sheet",
    fn(b, _) { @controls.button_node(b, fn() { "Sheet Btn" }, fn() {  }) |> ignore },
    from=Unanchored,
  )
  ts.run_for(settle)
  assert_eq(w4_overlays_open(), 1)
  ts.key(@ui.key_escape)
  ts.run_for(settle)
  assert_eq(w4_overlays_open(), 0)
  @controls.set_dark(None)
}

///|
test "W4-M1: drawer_node rubber-band over-pull, reverse-fling protection, and fling/Escape/outside dismiss" {
  let open = @signals.signal(true)
  let closes = Ref(0)
  let t = w4_tester(900.0, 640.0, fn(root) {
    root.box(fn(page) {
      page.grow(Is(1.0)) |> ignore
      @controls.drawer_node(
        page,
        fn() { open.get() },
        fn() { "Nav Drawer" },
        fn() {
          closes.val += 1
          open.set(false)
        },
        fn(b) {
          @controls.button_node(b, fn() { "Item" }, fn() {  }) |> ignore
        },
      )
    })
    |> ignore
    @controls.presented_nodes(root)
  })
  let settle = @ui.move_most_ms * 2.0
  t.run_for(settle)
  let rest_x = t.get(Dialog, label="Nav Drawer").rect.0
  assert_true((rest_x - 10.0).abs() < 1.0)

  // Over-pull right on Leading drawer is rubber-band clamped <= 16pt and stays open
  t.press_at(160.0, 320.0)
  t.hold_move(360.0, 320.0)
  let pulled_x = t.get(Dialog, label="Nav Drawer").rect.0
  assert_true(pulled_x > rest_x + 4.0 && pulled_x < rest_x + 16.0)
  t.advance(@ui.input_step_ms * 6.0)
  t.release(360.0, 320.0)
  t.run_for(settle)
  assert_eq((open.untracked(), closes.val), (true, 0))

  // Reverse-fling guard: drag past 32% threshold (~140pt left), then fling back right (> 450 pt/s) -> stays open!
  t.press_at(240.0, 320.0)
  for frac in [0.25, 0.5, 0.75, 1.0] {
    t.hold_move(240.0 - 150.0 * frac, 320.0)
  }
  // Quick rightward fling while still past 32% threshold (x from 90 -> 110 -> 130 -> delta still 110 > 96)
  t.hold_move(110.0, 320.0)
  t.hold_move(130.0, 320.0)
  t.release(130.0, 320.0)
  t.run_for(settle)
  assert_eq((open.untracked(), closes.val), (true, 0))

  // Fast closing fling (< 32% distance but > 450 pt/s leftward) commits close
  t.press_at(200.0, 320.0)
  t.hold_move(175.0, 320.0)
  t.hold_move(145.0, 320.0)
  t.release(145.0, 320.0)
  t.run_for(settle)
  assert_eq((open.untracked(), closes.val, w4_overlays_open()), (false, 1, 0))

  // Outside scrim tap dismisses
  open.set(true)
  t.run_for(settle)
  t.tap(700.0, 320.0)
  t.run_for(settle)
  assert_eq((open.untracked(), closes.val, w4_overlays_open()), (false, 2, 0))
  @controls.set_dark(None)
}

///|
test "W4-M1: menu_node keyboard nav, wrap, skip disabled, typeahead, and keep_field semantics" {
  let open = @signals.signal(false)
  let keep_field_open = @signals.signal(false)
  let chosen = Ref("")
  let field = @ui.Field::new()
  let anchor_ref : Ref[@view.View?] = Ref(None)
  let t = w4_tester(720.0, 520.0, fn(root) {
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((32.0, 32.0, 32.0, 32.0))).gap(Is(12.0)) |> ignore
      let inp = @controls.input_node(page, field, placeholder_by=fn() { "Compose" })
      anchor_ref.val = Some(inp)
      @controls.menu_node(
        page,
        fn() { open.get() },
        fn(_) { anchor_ref.val.unwrap() },
        fn() {
          [
            Some(w4_item("Section", heading=true)),
            Some(w4_item("Apple")),
            Some(w4_item("Apricot", disabled=true)),
            None,
            Some(w4_item("Avocado")),
            Some(w4_item("Banana")),
          ]
        },
        "Fruits",
        Start,
        6.0,
        false,
        false,
        fn(it) {
          chosen.val = it.label
          open.set(false)
        },
        fn() { open.set(false) },
      )
      @controls.menu_node(
        page,
        fn() { keep_field_open.get() },
        fn(_) { anchor_ref.val.unwrap() },
        fn() { [Some(w4_item("Bold")), Some(w4_item("Italic"))] },
        "Format",
        Start,
        6.0,
        false,
        true,
        fn(it) {
          chosen.val = it.label
          keep_field_open.set(false)
        },
        fn() { keep_field_open.set(false) },
      )
    })
    |> ignore
    @controls.presented_nodes(root)
  })
  let settle = @ui.move_most_ms * 2.0

  // Open menu: Down -> Apple, Down -> skips disabled Apricot & separator -> Avocado, Down -> Banana, Down -> wraps to Apple
  open.set(true)
  t.run_for(settle)
  t.key(@ui.key_code_down)
  let f1 = w4_focused_label(t)
  t.key(@ui.key_code_down)
  let f2 = w4_focused_label(t)
  t.key(@ui.key_code_down)
  let f3 = w4_focused_label(t)
  t.key(@ui.key_code_down)
  let f4 = w4_focused_label(t)
  // Up wraps back to Banana; Home -> Apple; End -> Banana
  t.key(@ui.key_code_up)
  let f5 = w4_focused_label(t)
  t.key(@ui.key_code_home)
  let f6 = w4_focused_label(t)
  t.key(@ui.key_code_end)
  let f7 = w4_focused_label(t)
  assert_eq((f1, f2, f3, f4, f5, f6, f7), ("Apple", "Avocado", "Banana", "Apple", "Banana", "Apple", "Banana"))

  // Typeahead: 'a' -> Apple, 'a' again -> cycles to Avocado (skipping disabled Apricot), Enter chooses Avocado
  t.key(@ui.key_of_char('a'))
  let ta1 = w4_focused_label(t)
  t.key(@ui.key_of_char('a'))
  let ta2 = w4_focused_label(t)
  t.key(@ui.key_code_enter)
  t.run_for(settle)
  assert_eq((ta1, ta2, chosen.val, open.untracked()), ("Apple", "Avocado", "Avocado", false))

  // keep_field=true: focus stays in field, Down does not steal focus onto Bold, Escape closes menu
  let (fx, fy, fw, fh) = t.get(TextField).rect
  t.tap(fx + fw / 2.0, fy + fh / 2.0)
  keep_field_open.set(true)
  t.run_for(settle)
  let before_down = t.focused().map(fn(s) { s.role })
  t.key(@ui.key_code_down)
  let after_down = t.focused().map(fn(s) { s.role })
  t.key(@ui.key_escape)
  t.run_for(settle)
  assert_eq((before_down, after_down, keep_field_open.untracked()), (Some(TextField), Some(TextField), false))
  @controls.set_dark(None)
}

///|
test "W4-M1: action_sheet_node keyboard wrap-around, Home/End, and Space activation" {
  let open = @signals.signal(true)
  let picked = Ref("")
  let anchor_ref : Ref[@view.View?] = Ref(None)
  let t = w4_tester(600.0, 480.0, fn(root) {
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((32.0, 32.0, 32.0, 32.0))) |> ignore
      let btn = @controls.button_node(page, fn() { "More" }, fn() {  })
      anchor_ref.val = Some(btn)
      @controls.action_sheet_node(
        page,
        fn() { open.get() },
        fn(_) { anchor_ref.val.unwrap() },
        fn() { "Options" },
        fn() { "" },
        fn() {
          [
            @controls.sheet_action("First", fn() { picked.val = "first" }),
            @controls.sheet_action("Second", fn() { picked.val = "second" }),
            @controls.sheet_action("Delete", fn() { picked.val = "delete" }, danger=true),
          ]
        },
        fn() { open.set(false) },
      )
    })
    |> ignore
    @controls.presented_nodes(root)
  })
  let settle = @ui.move_most_ms * 2.0
  t.run_for(settle)
  // Up from initial panel focus lands on last ("Delete"), Down wraps to "First", End -> "Delete", Home -> "First", Down -> "Second"
  t.key(@ui.key_code_up)
  let a1 = w4_focused_label(t)
  t.key(@ui.key_code_down)
  let a2 = w4_focused_label(t)
  t.key(@ui.key_code_end)
  let a3 = w4_focused_label(t)
  t.key(@ui.key_code_home)
  let a4 = w4_focused_label(t)
  t.key(@ui.key_code_down)
  let a5 = w4_focused_label(t)
  t.key(@ui.key_of_char(' '))
  t.run_for(settle)
  assert_eq((a1, a2, a3, a4, a5, picked.val, open.untracked(), w4_overlays_open()), (
    "Delete",
    "First",
    "Delete",
    "First",
    "Second",
    "second",
    false,
    0,
  ))
  @controls.set_dark(None)
}
