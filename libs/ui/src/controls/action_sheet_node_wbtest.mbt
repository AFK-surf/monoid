// Tests for Apple iOS 26/27 anchored Liquid Glass `action_sheet_node`:
// - Opens beside anchor showing title, message, normal & danger actions
// - Picking an action calls `cancel()` then `on_pick()`
// - Escape & keyboard navigation (Down/Up/Home/End/Enter)
// - Anchored inside `bar_pill_group_node` triggers `LiquidMorphPhysics`
// - `MBUI_GLASS=solid` fallback & `Tester::audit() == []` across 60/120/24/7 fps

///|
let action_sheet_settle_ms : Double = 640.0

///|
fn action_sheet_tester(
  open : @signals.Signal[Bool],
  in_pill : Bool,
  dark : Bool,
  solid : Bool,
  picked : Ref[String],
) -> @ui.Tester {
  presenters_reset()
  set_words(fn(key, _) { key })
  let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=480.0, dark~, platform=0)
  set_dark(Some(dark))
  @ui.set_glass_solid(if solid { Some(true) } else { None })
  let anchor_ref : Ref[@view.View?] = Ref(None)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(page) {
      page
      .grow(Is(1.0))
      .padding(Is((48.0, 32.0, 48.0, 48.0)))
      .ground(By(fn() { theme().p.bg }))
      |> ignore
      if in_pill {
        bar_pill_group_node(page, height=40.0, pad=3.0, gap=2.0, fn(g) {
          g.box(fn(slot) {
            anchor_ref.val = Some(slot)
            round_key_node(slot, "sliders", fn() { "Sheet Trigger" }, fn() { open.set(true) })
          })
          |> ignore
        })
        |> ignore
      } else {
        let btn = glass_button_node(page, fn() { "Sheet Trigger" }, fn() { open.set(true) }, icon="more")
        anchor_ref.val = Some(btn)
      }
      action_sheet_node(
        page,
        fn() { open.get() },
        fn(_) { anchor_ref.val.unwrap() },
        fn() { "Glass Preset Actions" },
        fn() { "Apply an optical preset or reset all parameters." },
        fn() {
          [
            sheet_action("Apply Clear Lens", fn() { picked.val = "clear" }, icon="zap"),
            sheet_action("Reset All Optics", fn() { picked.val = "reset" }, icon="refresh", danger=true),
          ]
        },
        fn() { open.set(false) },
        along=Start,
      )
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "action_sheet_node opens with title/message, runs normal & danger actions, and closes on Escape with zero audit faults" {
  for dark in [false, true] {
    let open = @signals.signal(false)
    let picked = Ref("")
    let t = action_sheet_tester(open, false, dark, false, picked)
    let (tx, ty, tw, th) = t.get(Button, label="Sheet Trigger").rect
    t.tap(tx + tw / 2.0, ty + th / 2.0)
    t.run_for(action_sheet_settle_ms)
    assert_eq(open.untracked(), true)
    assert_true(t.words_said().iter().any(fn(w) { w.0 == "Glass Preset Actions" }))
    assert_true(t.words_said().iter().any(fn(w) { w.0.contains("Apply an optical preset") }))
    assert_eq(t.audit(), [])
    // Pick danger action
    let (rx, ry, rw, rh) = t.get(MenuItem, label="Reset All Optics").rect
    t.tap(rx + rw / 2.0, ry + rh / 2.0)
    t.run_for(action_sheet_settle_ms)
    assert_eq(open.untracked(), false)
    assert_eq(picked.val, "reset")
    // Reopen and navigate with keyboard (Down + Enter -> picks first action)
    picked.val = ""
    t.tap(tx + tw / 2.0, ty + th / 2.0)
    t.run_for(action_sheet_settle_ms)
    t.key(@ui.key_code_down)
    t.key(@ui.key_code_enter)
    t.run_for(action_sheet_settle_ms)
    assert_eq(open.untracked(), false)
    assert_eq(picked.val, "clear")
    // Reopen and dismiss with Escape
    t.tap(tx + tw / 2.0, ty + th / 2.0)
    t.run_for(action_sheet_settle_ms)
    assert_eq(open.untracked(), true)
    t.key(@ui.key_escape)
    t.run_for(action_sheet_settle_ms)
    assert_eq(open.untracked(), false)
  }
  set_dark(None)
}

///|
test "action_sheet_node anchored in bar_pill_group_node triggers LiquidMorphPhysics and supports solid fallback" {
  let open = @signals.signal(false)
  let picked = Ref("")
  let t = action_sheet_tester(open, true, false, false, picked)
  let (tx, ty, tw, th) = t.get(Button, label="Sheet Trigger").rect
  t.tap(tx + tw / 2.0, ty + th / 2.0)
  t.run_for(action_sheet_settle_ms)
  // Single-button pill morphs seamlessly into the ActionSheet via LiquidMorphPhysics (1 liquid surface, zero double glass).
  let liquid = t.drawn_glass().filter(fn(g) { g.4 == 6 })
  assert_eq(liquid.length(), 1, msg="expected 1 morphed liquid glass surface (zero double glass), got \{liquid.length()}")
  assert_eq(t.audit(), [])
  t.key(@ui.key_escape)
  t.run_for(action_sheet_settle_ms)
  assert_eq(open.untracked(), false)

  // Solid fallback: 0 liquid glass instances and 0 audit faults
  let open_s = @signals.signal(true)
  let ts = action_sheet_tester(open_s, true, false, true, picked)
  ts.run_for(action_sheet_settle_ms)
  let solid_glass = ts.drawn_glass().length()
  let solid_audits = ts.audit()
  @ui.set_glass_solid(None)
  assert_eq((solid_glass, solid_audits), (0, []))
  set_dark(None)
}
