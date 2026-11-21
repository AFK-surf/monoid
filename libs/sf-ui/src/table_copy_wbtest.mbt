// A table's copy key (table_copy.mbt): hung past the table's right edge, in line with its head, taking no room; its
// menu copying it as Markdown, as CSV, or as a picture of it whole.

///|
/// A table the core read (its tree kept: src/sfkept), with its Markdown and CSV as the core wrote them.
let copy_table : String = "| 模型 | 输入 | 输出 | 缓存读 |\n| --- | --- | --- | --- |\n| Opus 5.5 | $5 | $25 | $0.5 |\n| Sonnet 5 | $3 | $15 | $0.3 |"

///|
/// `text` in a message's column (16 in, or a chat's margin past it that its tables scroll out over, `margin`, where that
/// is more), the presenters over it.
fn table_tester(platform : Int, w : Double, h : Double, text? : String = copy_table, margin? : Double = 0.0) -> @ui.Tester {
  presenters_reset()
  let pad = dmax(16.0, margin)
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w~, h~, platform~)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.lines_up(Is(None)) |> ignore
    root.box(fn(col) {
      col.padding(Is((pad, pad, pad, pad))) |> ignore
      markdown_node(col, fn() { text }, bleed=fn() { margin }) |> ignore
    })
    |> ignore
    @ui.old(root, fn(c) {
      begin(c) |> ignore
      c.with_theme(ui_theme(), fn() { presented(c) })
    }).over(Is(true)) |> @ui.old_takes_own |> ignore
    presented_nodes(root)
  })
  t
}

///|
/// The table's key, as a screen reader finds it.
fn table_key_of(tt : @ui.Tester, copied? : Bool = false) -> (Double, Double, Double, Double) raise {
  tt.get(Button, label=if copied { t("common.copied") } else { t("web-main.prose.copyTable") }).rect
}

///|
test "a table's copy key hangs past its right edge, in line with its head; its menu copies it as CSV, as Markdown" {
  let tt = table_tester(2, 390.0, 844.0)
  tt.draw()
  tt.draw()
  let (kx, ky, kw, kh) = table_key_of(tt)
  let (lx, hy, lw, hh) = tt.rect_of("缓存读").unwrap()
  // its gap past the head's last words (nothing after them), within the message's column; its middle on theirs
  assert_true(kx >= lx + lw + table_key_gap && kx + kw <= 390.0 - 16.0, msg="\{Repr((kx, kw, lx, lw))}")
  assert_true((ky + kh / 2.0 - (hy + hh / 2.0)).abs() <= 1.0, msg="\{Repr((ky, kh, hy, hh))}")
  tt.click(Button, label=t("web-main.prose.copyTable"))
  tt.run_for(presented_rest() - tt.time())
  tt.tap_text(t("web-main.prose.copyCsv"))
  assert_eq(tt.clipboard(), "模型,输入,输出,缓存读\nOpus 5.5,$5,$25,$0.5\nSonnet 5,$3,$15,$0.3")
  tt.frame()
  // a check a moment
  let _ = table_key_of(tt, copied=true)
  tt.click(Button, label=t("common.copied"))
  tt.run_for(presented_rest() - tt.time())
  tt.tap_text(t("web-main.prose.copyMarkdown"))
  assert_eq(tt.clipboard(), copy_table)
}

///|
test "a table as wide as a phone's message: its key over nothing of it, past its end, scrolled to" {
  let long = "a long cell of words that would wrap to a word or two if squeezed into the message"
  let text = "| 一 | 二 | 三 |\n|---|---|---|\n| one \{long} | two \{long} | three \{long} |\n"
  let t = table_tester(2, 390.0, 844.0, text~, margin=16.0)
  t.draw()
  t.draw()
  // at rest past the screen's edge
  let (kx, ky, _, _) = table_key_of(t)
  assert_true(kx >= 390.0, msg="\{kx}")
  // scrolled to the end: past the table's last words, within the words' column
  for _ in 0..<6 {
    t.drag(370.0, ky + 40.0, 20.0, ky + 40.0)
    t.draw()
  }
  t.run_for(@ui.move_most_ms)
  let (kx, _, kw, _) = table_key_of(t)
  let (lx, _, lw, _) = t.rect_of("three a long").unwrap()
  assert_true(kx > lx + lw && (kx + kw - (390.0 - 16.0 - table_key_gap)).abs() < 0.01, msg="\{Repr((kx, kw, lx, lw))}")
}

///|
test "a table as wide as the message on a wide chat: its key out in the margin, nothing to scroll" {
  let long = "a long cell of words that would wrap to a word or two if squeezed into the message"
  let text = "| 一 | 二 | 三 |\n|---|---|---|\n| one \{long} | two \{long} | three \{long} |\n"
  // (a message 760 wide, 160 of margin either side: Large's)
  let t = table_tester(0, 1080.0, 800.0, text~, margin=160.0)
  t.draw()
  t.draw()
  // (pointed at: its key shown)
  let (ox, oy, _, _) = t.rect_of("一").unwrap()
  t.move_to(ox, oy)
  t.run_for(dur_ms)
  // past the table's last words, in the margin, whole
  let (kx, _, kw, _) = table_key_of(t)
  let (lx, ly, lw, _) = t.rect_of("three a long").unwrap()
  assert_true(kx > lx + lw && kx >= 1080.0 - 160.0 && kx + kw <= 1080.0 - 160.0 + table_key_room, msg="\{Repr((kx, kw, lx, lw))}")
  // a drag moves nothing: no more to see
  t.drag(600.0, ly, 200.0, ly)
  t.draw()
  t.frame()
  let (lx2, _, _, _) = t.rect_of("three a long").unwrap()
  assert_eq(lx2, lx)
}

///|
test "a table in the message, no card round it: its words in line with the message's, its rules from them to its last column's" {
  let text = "| 人想按什么看 | 背后的事实 | 谁知道 |\n|---|---|---|\n| 项目（still.fail、mbui、示例项目…） | agent 改了哪个仓库、开了哪个 PR、用了哪个「项目记忆」 | station 已经知道（PR 链接本来就会抽出来放进「PR」那一栏） |\n| 要不要我管 | 等你 / 在干活 / 出错 / 没事 | 已经有了（状态点） |\n| 结果怎样 | PR 开着 / 已合 / 检查红了 | 同上 |\n"
  for size in [(1080.0, 160.0), (800.0, 16.0), (390.0, 16.0)] {
    let (w, margin) = size
    let t = table_tester(0, w, 800.0, text~, margin~)
    t.draw()
    t.draw()
    t.frame()
    let rects = t.drawn_rects()
    let rules = rects.filter(fn(r) { r.3 == 1.0 })
    assert_eq(rules.length(), 3)
    // the head's first words where the message's are (its column `margin` in, 16 at the least)
    let (words, _) = t.drawn_of("人想按什么看").unwrap()
    assert_eq(words, dmax(16.0, margin))
    for rule in rules {
      // from them, past the last column's words, on nothing drawn (no card)
      assert_eq(rule.0, words)
      match t.rect_of("同上") {
        // (where it shows whole: not scrolled out of a phone's message)
        Some((lx, _, lw, _)) if lx + lw < w => assert_true(rule.0 + rule.2 >= lx + lw, msg="\{Repr((w, rule, lx, lw))}")
        _ => ()
      }
      let under = rects.filter(fn(r) { r.2 < w && r.3 > 1.0 && r.0 <= rule.0 && r.0 + r.2 >= rule.0 + rule.2 && r.1 < rule.1 && r.1 + r.3 > rule.1 })
      assert_eq(under.length(), 0, msg="\{Repr((w, under))}")
    }
  }
}

///|
test "a table's copy key with a mouse: shown as the table is pointed at, its menu open, gone as the pointer leaves" {
  let tt = table_tester(0, 1280.0, 800.0)
  tt.draw()
  tt.draw()
  // (built, under its menu too: hidden from a reader there)
  let copy_table_label = t("web-main.prose.copyTable")
  let keys = fn() {
    tt.semantics().filter(fn(s) { s.role == Button && s.label == copy_table_label }).length()
  }
  // at rest: none
  assert_eq(keys(), 0)
  // pointed at the table's last row: there, faded in
  let (lx, ly, _, lh) = tt.rect_of("Sonnet 5").unwrap()
  tt.move_to(lx, ly + lh / 2.0)
  tt.run_for(dur_ms)
  assert_eq(keys(), 1)
  // its menu open, the pointer gone into it: still there
  tt.click(Button, label=copy_table_label)
  tt.run_for(@motion.presence_in_ms)
  tt.move_to(lx, 780.0)
  tt.run_for(dur_ms)
  assert_eq(keys(), 1)
  // the menu closed by a press outside it, the pointer off the table: gone
  tt.tap(lx, 780.0)
  tt.run_for(@motion.presence_in_ms + dur_ms)
  assert_eq(keys(), 0)
}

///|
test "a table's copy key with a mouse: its picture copied whole, the key not in it" {
  let tt = table_tester(0, 1280.0, 800.0)
  tt.draw()
  tt.draw()
  let (lx, ly, _, _) = tt.rect_of("缓存读").unwrap()
  tt.move_to(lx, ly)
  tt.run_for(dur_ms)
  tt.click(Button, label=t("web-main.prose.copyTable"))
  tt.run_for(@motion.presence_in_ms)
  tt.tap_text(t("desktop.contextMenu.copyImage"))
  tt.frame()
  tt.frame()
  // the table whole, on its own, on the clipboard; its key a check a moment
  let shots = tt.shots()
  assert_eq(shots.length(), 1)
  assert_true(shots[0].iter().any(fn(w) { w.contains("缓存读") }) && shots[0].iter().any(fn(w) { w.contains("Sonnet 5") }))
  assert_true(tt.clipboard_png() is Some(_))
  let _ = table_key_of(tt, copied=true)
  tt.move_to(lx, ly)
  tt.run_for(copied_ms)
  let _ = table_key_of(tt)
}

///|
test "two messages' tables: the picture copied is of the table whose key was pressed" {
  // (each message's first table: the same key in its own message)
  let long = "a long cell of words that would wrap to a word or two if squeezed into the message"
  let other = "| 一 | 二 | 三 |\n|---|---|---|\n| one \{long} | two \{long} | three \{long} |\n"
  presenters_reset()
  let tt = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=1280.0, h=800.0, platform=0)
  tt.check_looks(false)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.lines_up(Is(None)) |> ignore
    root.box(fn(col) {
      col.padding(Is((16.0, 16.0, 16.0, 16.0))) |> ignore
      markdown_node(col, fn() { copy_table }) |> ignore
      markdown_node(col, fn() { other }) |> ignore
    })
    |> ignore
    @ui.old(root, fn(c) {
      begin(c) |> ignore
      c.with_theme(ui_theme(), fn() { presented(c) })
    }).over(Is(true)) |> @ui.old_takes_own |> ignore
    presented_nodes(root)
  })
  tt.draw()
  tt.draw()
  let (lx, ly, _, _) = tt.rect_of("缓存读").unwrap()
  tt.move_to(lx, ly)
  tt.run_for(dur_ms)
  tt.click(Button, label=t("web-main.prose.copyTable"))
  tt.run_for(@motion.presence_in_ms)
  tt.tap_text(t("desktop.contextMenu.copyImage"))
  tt.frame()
  tt.frame()
  let shots = tt.shots()
  assert_eq(shots.length(), 1)
  assert_true(shots[0].iter().any(fn(w) { w.contains("缓存读") }), msg="\{Repr(shots[0])}")
  assert_false(shots[0].iter().any(fn(w) { w.contains("three a long") }), msg="\{Repr(shots[0])}")
}
