// Wave 4 Stage 2 (W4-M2) regression tests for controls migrated to `@headless` and `@ui.agent_secret`:
// hover_card_node, submenu_row_node, tip_node, inline_rename_node, reader_layout_node slider,
// progress_ring_node, progress_spinner_node, secret_value_row_node, input_bar_node, textarea_node.

///|
let w4_m2_short_ms : Double = 20.0

///|
let w4_m2_settled_ms : Double = 200.0

///|
fn w4_m2_tester(w? : Double = 800.0, h? : Double = 500.0, platform? : Int = 0, body : (@view.View) -> Unit) -> @ui.Tester {
  let t = @ui.Tester::new(fn(c) { @controls.begin(c) |> ignore }, w~, h~, platform~)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(@controls.ui_theme_now)
    body(root)
  })
  t.draw()
  t
}

///|
test "w4-m2: hover_card_node delay, bridge, held, and outside-press dismiss via @headless.HoverCard" {
  let held = @signals.signal(false)
  let hand : Ref[@controls.HoverHand?] = Ref(None)
  let t = w4_m2_tester(fn(root) {
    let layer : Ref[@view.View?] = Ref(None)
    let tips = @controls.TipLayer::new(fn() { layer.val })
    root.box(fn(k) {
      k
      .margin(Is((40.0, 40.0, 0.0, 0.0)))
      .width(Is(Some(120.0)))
      .height(Is(Some(32.0)))
      .says(Is(Some(@view.said(Button, label="卡片触发"))))
      |> ignore
      hand.val = Some(
        @controls.hover_card_node(
          tips,
          k,
          fn(b) { b.box(fn(w) { w.words(Is("悬浮内容")) |> ignore }) |> ignore },
          held=fn() { held.get() },
          press=fn() {  },
        ),
      )
    })
    |> ignore
    layer.val = Some(root.box(fn(l) { l.over(Is(true)).over_all(Is(true)) |> ignore }))
  })
  let is_open = fn() { hand.val is Some(h) && @signals.untracked(h.open) }
  // Open after hover_card_open_ms
  t.move_to(80.0, 56.0)
  t.run_for(@controls.hover_card_open_ms - w4_m2_short_ms)
  assert_false(is_open(), msg="not open before open delay")
  t.run_for(w4_m2_short_ms + w4_m2_settled_ms)
  assert_true(is_open(), msg="open after open delay")
  // Bridge onto card keeps open
  let card_rect = t.semantics().iter().find_first(fn(s) { s.role == Group && !s.hidden }).unwrap().rect
  t.move_to(card_rect.0 + 20.0, card_rect.1 + 12.0)
  t.run_for(@controls.hover_card_close_ms + w4_m2_settled_ms)
  assert_true(is_open(), msg="bridging to card keeps open")
  // Held suppresses leave & outside press
  held.set(true)
  t.move_to(700.0, 420.0)
  t.run_for(@controls.hover_card_close_ms + w4_m2_settled_ms)
  assert_true(is_open(), msg="held keeps open on leave")
  t.tap(700.0, 420.0)
  t.run_for(w4_m2_settled_ms)
  assert_true(is_open(), msg="held keeps open on outside press")
  // Release held, then outside press closes immediately
  held.set(false)
  t.move_to(80.0, 56.0)
  t.run_for(w4_m2_short_ms)
  t.tap(700.0, 420.0)
  t.run_for(w4_m2_settled_ms)
  assert_false(is_open(), msg="outside press closes once not held")
}

///|
test "w4-m2: submenu_row_node aiming corridor and touch open via @headless.Submenu" {
  // Aim corridor geometry from @headless.submenu_in_aim_corridor
  assert_true(@headless.submenu_in_aim_corridor(150.0, 110.0, 100.0, 100.0, 200.0, 80.0, 120.0, 100.0))
  assert_false(@headless.submenu_in_aim_corridor(150.0, 300.0, 100.0, 100.0, 200.0, 80.0, 120.0, 100.0))
  // Touch open on Medium/Large stays open past close delay until outside tap
  let picked = Ref(0)
  let t = w4_m2_tester(w=900.0, h=600.0, platform=1, fn(root) {
    root.box(fn(panel) {
      panel.margin(Is((40.0, 40.0, 0.0, 0.0))).width(Is(Some(180.0))) |> ignore
      @controls.submenu_row_node(panel, fn() { "导出格式" }, fn() {
        [Some(@controls.menu_item_of("导出 PDF", fn() { picked.val += 1 }))]
      })
    })
    |> ignore
  })
  let word_mid = fn(w : String) -> (Double, Double)? {
    match t.words().filter(fn(x) { x.0 == w && x.5 > 0.5 }).last() {
      Some(x) => Some((x.1 + x.3 / 2.0, x.2 + x.4 / 2.0))
      None => None
    }
  }
  guard word_mid("导出格式") is Some((rx, ry)) else { fail("missing submenu row") }
  t.tap(rx, ry)
  t.run_for(@controls.submenu_close_ms + w4_m2_settled_ms)
  assert_true(word_mid("导出 PDF") is Some(_), msg="touch-opened submenu stays open past close delay")
  t.tap(750.0, 500.0)
  t.run_for(w4_m2_settled_ms)
  assert_true(word_mid("导出 PDF") is None, msg="outside tap closes touch-opened submenu")
}

///|
test "w4-m2: tip_node warmup, Role::Tooltip, and repeats truncation via @headless.TooltipGroup" {
  let t = w4_m2_tester(w=600.0, h=300.0, platform=0, fn(root) {
    let layer : Ref[@view.View?] = Ref(None)
    let tips = @controls.TipLayer::new(fn() { layer.val })
    root.row(Is(true)).gap(Is(12.0)).padding(Is((20.0, 20.0, 20.0, 20.0))) |> ignore
    for name in ["第一项", "第二项"] {
      root.box(fn(k) {
        k.width(Is(Some(60.0))).height(Is(Some(32.0))).says(Is(Some(@view.said(Button, label=name)))) |> ignore
        @controls.tip_node(tips, k, fn() { "提示：" + name }) |> ignore
      })
      |> ignore
    }
    // Truncated label with repeats=true vs untruncated with repeats=true
    root.box(fn(k) {
      k.row(Is(true)).width(Is(Some(48.0))).height(Is(Some(32.0))).says(Is(Some(@view.said(Button, label="短框")))) |> ignore
      k.box(fn(n) {
        n.cuts(Is(true)).words(Is("非常长会被截断的标题文字")).words_look(Is({ ..@view.words_plain, wrap: false })) |> ignore
      })
      |> ignore
      @controls.tip_node(tips, k, fn() { "非常长会被截断的标题文字" }, repeats=true, skip=false) |> ignore
    })
    |> ignore
    root.box(fn(k) {
      k.row(Is(true)).width(Is(Some(260.0))).height(Is(Some(32.0))).says(Is(Some(@view.said(Button, label="宽框")))) |> ignore
      k.box(fn(n) {
        n.cuts(Is(true)).words(Is("短字")).words_look(Is({ ..@view.words_plain, wrap: false })) |> ignore
      })
      |> ignore
      @controls.tip_node(tips, k, fn() { "短字" }, repeats=true, skip=false) |> ignore
    })
    |> ignore
    layer.val = Some(root.box(fn(l) { l.over(Is(true)) |> ignore }))
  })
  let tips_shown = fn() { t.semantics().filter(fn(s) { s.role == Tooltip && !s.hidden }).map(fn(s) { s.label }) }
  let b1 = t.get(Button, label="第一项").rect
  let b2 = t.get(Button, label="第二项").rect
  t.move_to(b1.0 + 10.0, b1.1 + 10.0)
  t.run_for(@headless.tooltip_delay_ms + w4_m2_settled_ms)
  assert_eq(tips_shown(), ["提示：第一项"], msg="cold tip opens after delay")
  // Warmup: moving to second button opens immediately without waiting tooltip_delay_ms
  t.move_to(b2.0 + 10.0, b2.1 + 10.0)
  t.run_for(w4_m2_short_ms)
  assert_eq(tips_shown(), ["提示：第二项"], msg="warm tip opens immediately")
  // repeats=true: truncated shows, untruncated stays hidden
  let b_cut = t.get(Button, label="短框").rect
  t.move_to(b_cut.0 + 10.0, b_cut.1 + 10.0)
  t.run_for(@headless.tooltip_delay_ms + w4_m2_settled_ms)
  assert_eq(tips_shown(), ["非常长会被截断的标题文字"], msg="repeats=true shows when truncated")
  let b_wide = t.get(Button, label="宽框").rect
  t.move_to(b_wide.0 + 10.0, b_wide.1 + 10.0)
  t.run_for(@headless.tooltip_delay_ms + w4_m2_settled_ms)
  assert_eq(tips_shown(), [], msg="repeats=true hides when not truncated")
}

///|
test "w4-m2: inline_rename_node trim, empty cancel, unchanged cancel, and outside press commit" {
  for case in [("  新标题  ", "commit:新标题"), ("   ", "cancel"), ("原标题", "cancel")] {
    let (typed, expected) = case
    let f = @ui.Field::new(text="原标题")
    let out : Array[String] = []
    let opened = @signals.signal(false)
    let t = w4_m2_tester(w=400.0, h=300.0, fn(root) {
      root.box(fn(e) {
        e
        .width(Is(Some(60.0)))
        .height(Is(Some(40.0)))
        .presses(Is(true))
        .focusable(Is(true))
        .says(Is(Some(@view.said(Button, label="外面"))))
        .on_press(fn() {  })
        |> ignore
      })
      |> ignore
      root.show(fn() { opened.get() }, fn(s) {
        s.box(fn(b) {
          b.width(Is(Some(240.0))) |> ignore
          @controls.inline_rename_node(
            b,
            f,
            "原标题",
            "重命名",
            fn(w) { out.push("commit:" + w) },
            fn() { out.push("cancel") },
          )
          |> ignore
        })
        |> ignore
      })
    })
    opened.set(true)
    t.draw()
    f.set(typed)
    t.draw()
    let ext = t.get(Button, label="外面").rect
    t.tap(ext.0 + ext.2 / 2.0, ext.1 + ext.3 / 2.0)
    t.draw()
    assert_eq(out, [expected], msg="case=\{typed}")
  }
}

///|
test "w4-m2: reader_layout_node slider drag-release commit and keyboard step via @headless.slider" {
  let style_sig : @signals.Signal[@controls.ReaderStyle] = @signals.signal(
    { paper: "white", size: 18, line: 1.6, margin: 40, face: "serif", indent: true },
  )
  let commits : Array[Double] = []
  let prev = @controls.viewer_host()
  @controls.set_viewer_host({
    ..prev,
    reader_style: fn() { style_sig.get() },
    set_reader_style: fn(ch) {
      match ch {
        Line(v) => {
          commits.push(v)
          style_sig.set({ ..style_sig.untracked(), line: v })
        }
        Margin(m) => style_sig.set({ ..style_sig.untracked(), margin: m })
        _ => ()
      }
    },
  })
  let t = w4_m2_tester(w=800.0, h=600.0, fn(root) {
    @controls.reader_layout_docked(root, fn() {  })
  })
  let sliders = t.semantics().filter(fn(s) { s.role == Slider })
  assert_true(sliders.length() >= 2, msg="reader layout exposes 2 sliders")
  let line_slider = sliders[0]
  // Drag right and release -> commits once on release
  let y = line_slider.rect.1 + line_slider.rect.3 / 2.0
  let x1 = line_slider.rect.0 + line_slider.rect.2 * 0.8
  t.press_at(line_slider.rect.0 + line_slider.rect.2 * 0.5, y)
  t.move_to(x1, y)
  assert_eq(commits.length(), 0, msg="drag does not commit before release")
  t.release(x1, y)
  t.draw()
  assert_eq(commits.length(), 1, msg="release commits new line height")
  let after_drag = style_sig.untracked().line
  // Keyboard step right -> commits immediately
  t.key(@ui.key_code_right)
  t.draw()
  assert_true(style_sig.untracked().line > after_drag || after_drag >= 2.2, msg="keyboard right steps slider")
  @controls.set_viewer_host(prev)
}

///|
test "w4-m2: progress_ring_node and progress_spinner_node expose Role::ProgressBar and range" {
  let part = @signals.signal(0.4)
  let coming : @signals.Signal[Double?] = @signals.signal(None)
  let t = w4_m2_tester(w=300.0, h=200.0, fn(root) {
    @controls.progress_ring_node(root, 20.0, fn() { part.get() }, fn() { 0xFFFFFFFFL }, label=fn() { "下载环" })
    |> ignore
    @controls.progress_spinner_node(root, fn() { coming.get() }, label=fn() { "同步中" }) |> ignore
  })
  let ring = t.get(ProgressBar, label="下载环")
  assert_eq(ring.range, Some((0.0, 0.4, 1.0)))
  assert_eq(ring.value, "40%")
  let spin_indet = t.get(ProgressBar, label="同步中")
  assert_eq(spin_indet.range, None, msg="spinner None is indeterminate")
  coming.set(Some(0.75))
  t.draw()
  let spin_det = t.get(ProgressBar, label="同步中")
  assert_eq(spin_det.range, Some((0.0, 0.75, 1.0)))
  assert_eq(spin_det.value, "75%")
}

///|
test "w4-m2: secret_value_row_node redacts plaintext in agent_snapshot and blocks agent_query when shown" {
  let secret_val = "sk_live_w4m2_topsecret_9981"
  let t = w4_m2_tester(w=400.0, h=200.0, fn(root) {
    root.box(fn(row) {
      @controls.secret_value_row_node(
        row,
        fn() { "API 密钥" },
        fn() { secret_val },
        shown=fn() { true },
        mono=fn() { true },
        fn(_) {  },
      )
    })
    |> ignore
  })
  let snap = t.agent_snapshot()
  let json = @ui.agent_snapshot_json(snap)
  assert_true(!json.contains(secret_val), msg="plaintext secret must never appear in agent_snapshot")
  assert_true(json.contains("[redacted]"), msg="secret_value_row_node must be redacted in agent_snapshot")
  assert_eq(t.agent_query(text=secret_val).length(), 0, msg="agent_query must not find plaintext secret")
  assert_eq(t.agent_query(text="topsecret_9981").length(), 0, msg="agent_query must not find secret substring")
}

///|
test "w4-m2: input_bar_node and textarea_node wire @headless.TextField description, invalid, and error" {
  let f1 = @ui.Field::new(text="abc")
  let f2 = @ui.Field::new(text="notes")
  let invalid = @signals.signal(false)
  let t = w4_m2_tester(w=400.0, h=300.0, fn(root) {
    @controls.input_bar_node(
      root,
      f1,
      label="用户名",
      description=fn() { "输入小写字母" },
      error=fn() { "格式不正确" },
      invalid=fn() { invalid.get() },
    )
    |> ignore
    @controls.textarea_node(
      root,
      f2,
      label="备注",
      description=fn() { "可选说明" },
      error=fn() { "备注过长" },
      invalid=fn() { invalid.get() },
    )
    |> ignore
  })
  assert_eq(t.get(TextField, label="用户名").description, "输入小写字母")
  assert_eq(t.get(TextField, label="备注").description, "可选说明")
  invalid.set(true)
  t.draw()
  assert_eq(t.get(TextField, label="用户名").description, "格式不正确")
  assert_eq(t.get(TextField, label="备注").description, "备注过长")
}
