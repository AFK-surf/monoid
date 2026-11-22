// Tests for `field_bar_node`: liquid-glass editing bar over a focused text field, above/below flip,
// narrow 320pt + 1.3x + English 4-item fit with zero truncation and zero audit faults, and actions.

///|
fn field_bar_tester(
  f : @ui.Field,
  w? : Double = 390.0,
  h? : Double = 844.0,
  y? : Double = 300.0,
  words_scale? : Double = 1.0,
  labels? : FieldBarLabels = { cut: "剪切", copy: "复制", paste: "粘贴", select_all: "全选" },
  copied? : Ref[Int] = Ref(0),
) -> @ui.Tester {
  let t = @ui.Tester::new(
    fn(_c) {  },
    w~,
    h~,
    platform=2,
    pointing=Finger,
    native=Finger,
  )
  if words_scale != 1.0 {
    t.set_font_scale(words_scale)
  }
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    @ui.field_menu_bar(root) |> ignore
    root.box(fn(box) {
      box.over(Is(true)).offset(Is((16.0, y))).width(Is(Some(w - 32.0))).clips(Is(true)) |> ignore
      @ui.field(box, f, label="输入框", font_size=15.0, max_lines=3) |> ignore
    })
    |> ignore
    field_bar_node(root, fn() { true }, fn() { labels }, on_copied=fn() { copied.val += 1 })
  })
  t.draw()
  t
}

///|
test "field_bar_node shows liquid-glass editing bar on 390pt, executes select all and copy, and dismisses outside" {
  let f = @ui.Field::new(text="拆拜拜 明天见")
  let copied = Ref(0)
  let t = field_bar_tester(f, copied~)
  // Long-press word -> custom bar appears above selection, system menu suppressed
  t.press_at(40.0, 310.0)
  t.run_for(@ui.long_press_ms + @ui.frame_period_default)
  t.release(40.0, 310.0)
  t.run_for(@motion.pop_ms)
  assert_false(t.text_menu().0)
  assert_true(t.find("剪切") is Some(_), msg="missing 剪切")
  assert_true(t.find("复制") is Some(_), msg="missing 复制")
  assert_true(t.find("粘贴") is Some(_), msg="missing 粘贴")
  assert_true(t.find("全选") is Some(_), msg="missing 全选")
  let (_, copy_y) = t.find("复制").unwrap()
  assert_true(copy_y < 300.0, msg="bar should sit above selection: y=\{copy_y}")
  assert_eq(t.audit(), [], msg="audit faults on 390pt")
  // Tap 全选 -> selects all text, 全选 hides while bar stays open
  let (ax, ay) = t.find("全选").unwrap()
  t.tap(ax, ay)
  t.run_for(@motion.pop_ms)
  assert_eq(f.selection(), (0, f.text().length()))
  assert_true(t.find("复制") is Some(_))
  assert_true(t.find("全选") is None)
  // Tap 复制 -> triggers on_copied and closes bar
  let (cx, cy) = t.find("复制").unwrap()
  t.tap(cx, cy)
  t.run_for(@motion.pop_out_ms)
  assert_eq(copied.val, 1)
  assert_true(t.find("复制") is None)
  // Re-open bar and tap outside -> dismisses immediately
  t.press_at(40.0, 310.0)
  t.run_for(@ui.long_press_ms + @ui.frame_period_default)
  t.release(40.0, 310.0)
  t.run_for(@motion.pop_ms)
  assert_true(t.find("复制") is Some(_))
  t.tap(200.0, 600.0)
  t.run_for(@motion.pop_out_ms)
  assert_true(t.find("复制") is None)
}

///|
test "field_bar_node on 320x568 at 1.3x font scale with English 4 actions has zero truncation and zero audit faults" {
  let f = @ui.Field::new(text="hello world again")
  let t = field_bar_tester(
    f,
    w=320.0,
    h=568.0,
    y=260.0,
    words_scale=1.3,
    labels={ cut: "Cut", copy: "Copy", paste: "Paste", select_all: "Select All" },
  )
  t.press_at(45.0, 272.0)
  t.run_for(@ui.long_press_ms + @ui.frame_period_default)
  t.release(45.0, 272.0)
  t.run_for(@motion.pop_ms)
  let runs = t.text_runs()
  for word in ["Cut", "Copy", "Paste", "Select All"] {
    assert_true(t.find(word) is Some(_), msg="missing \{word} on 320pt 1.3x")
    let matched = runs.filter(fn(r) { r.text == word })
    assert_true(!matched.is_empty(), msg="truncated or missing text run for \{word}")
    for r in matched {
      assert_true(r.x0 >= 0.0 && r.x1 <= 320.0, msg="\{word} overflows 320pt window: x0=\{r.x0}, x1=\{r.x1}")
    }
  }
  assert_eq(t.audit(), [], msg="audit faults on 320pt 1.3x English")
}

///|
test "field_bar_node flips below selection and clears 18pt teardrop handle when field is near top of window" {
  let f = @ui.Field::new(text="search query")
  let t = field_bar_tester(f, w=390.0, h=844.0, y=16.0)
  t.press_at(45.0, 26.0)
  t.run_for(@ui.long_press_ms + @ui.frame_period_default)
  t.release(45.0, 26.0)
  t.run_for(@motion.pop_ms)
  let (_, copy_y) = t.find("复制").unwrap()
  assert_true(copy_y >= 16.0 + 20.0 + 18.0, msg="flipped bar must clear the 18pt teardrop handle: y=\{copy_y}")
  assert_eq(t.audit(), [], msg="audit faults when flipped below")
}
