// A dialog's head whose title takes two lines: its close button at the head's end, and a step's back key before its
// title, stand on the title's first line where they stood by a title of one line, never centred on the two lines
// (head_line_drop, dialog_step_head, panel_step_line, sheet_title_row: 「这种不应该对标题居中」). Measured as how far a
// button's middle is from the middle of its title's first line, with a title of one line and of two.

///|
/// How far the middle of the button called `button` stands under the middle of the first line of `title` in what `open`
/// presents on a window `w` wide (中屏 a dialog, 小屏 a sheet) at the system's size of words `scale`, opened by 打开; and
/// how many lines the title takes.
fn head_button_off(
  open : (Anchor) -> Unit,
  title : String,
  button : String,
  w? : Double = 1200.0,
  scale? : Double = 1.0,
) -> (Double, Int) {
  presenters_reset()
  let t = @ui.Tester::new(
    fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
    tree=presented_tree(presenting_view(open)),
    w~,
    h=800.0,
    platform=0,
  )
  t.check_looks(false)
  t.set_font_scale(scale)
  t.draw()
  t.tap_text("打开")
  t.run_for(@ui.move_most_ms)
  t.leave()
  t.draw()
  let words = t.words().filter(fn(x) { x.0 == title })
  let lines = t.lines_of(title).length()
  let b = t.all(Button, label=button)
  guard words.length() == 1 && lines > 0 && b.length() == 1 else {
    @halt.saying("no \{title} or \{button}: \{words.length()} \{lines} \{b.length()}")
  }
  let (_, _, y, _, h, _) = words[0]
  let first_mid = y + h / lines.to_double() / 2.0
  let (_, by, _, bh) = b[0].rect
  ((by + bh / 2.0 - first_mid).round(), lines)
}

///|
let head_long_title : String = "OPPO Find X9 Ultra 上的 still 应用申请工作区密钥库的钥匙，请核对以下信息后再授权"

///|
test "a dialog's close button stands on its title's first line, the title of one line or of two" {
  let close = t("common.close")
  let dialog = fn(title : String) {
    fn(_ : Anchor) {
      panel_nodes(title, from=Unanchored, description="此设备已在你的受信任设备中。", fn(v, _) {
        v.box(fn(b) { words_node(b, fn() { "内容" }, fn() { dialog_lead }) |> ignore }) |> ignore
      })
    }
  }
  let (one, one_lines) = head_button_off(dialog("申请钥匙"), "申请钥匙", close)
  let (two, two_lines) = head_button_off(dialog(head_long_title), head_long_title, close)
  assert_eq((one_lines, two_lines >= 2), (1, true))
  assert_eq(two, one)
}

///|
test "a step's back key in a dialog and on a sheet stands on its title's first line, the title of one line or of two" {
  let back = t("common.back")
  let stepped = fn(title : String) {
    fn(_ : Anchor) {
      panel_nodes("第一步", from=Unanchored, steps=true, fn(v, _) {
        v.box(fn(b) { words_node(b, fn() { "内容" }, fn() { dialog_lead }) |> ignore }) |> ignore
      })
      panel_go_nodes(title, fn(v, _) {
        v.box(fn(b) { words_node(b, fn() { "下一步的内容" }, fn() { dialog_lead }) |> ignore }) |> ignore
      })
    }
  }
  // (on the first line's middle itself, at any size of words: a key a line of words tall, in_line's)
  for w in [1200.0, 390.0] {
    for scale in [0.85, 1.0, 1.3, 1.8, 2.0] {
      let at = "\{w} \{scale}"
      let (one, one_lines) = head_button_off(stepped("申请钥匙"), "申请钥匙", back, w~, scale~)
      let (two, two_lines) = head_button_off(stepped(head_long_title), head_long_title, back, w~, scale~)
      assert_eq((one_lines, two_lines >= 2), (1, true), msg=at)
      assert_eq((one, two), (0.0, 0.0), msg=at)
    }
  }
}

///|
test "a sheet's step's back key stands concentric with the sheet's top corner and flush with body words across scales" {
  for title in ["申请钥匙", head_long_title] {
    for scale in [0.85, 1.0, 1.3, 1.8, 2.0] {
      let at = "\{title} scale=\{scale}"
      let open = fn(_ : Anchor) {
        panel_nodes("第一步", from=Unanchored, steps=true, fn(v, _) {
          v.box(fn(b) { words_node(b, fn() { "内容" }, fn() { dialog_lead }) |> ignore }) |> ignore
        })
        panel_go_nodes(title, fn(v, _) {
          v.box(fn(b) { words_node(b, fn() { "下一步的内容" }, fn() { dialog_lead }) |> ignore }) |> ignore
        })
      }
      presenters_reset()
      let back = t("common.back")
      let tt = @ui.Tester::new(
        fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
        tree=presented_tree(presenting_view(open)),
        w=390.0,
        h=800.0,
        platform=0,
      )
      tt.check_looks(false)
      tt.set_font_scale(scale)
      tt.draw()
      tt.tap_text("打开")
      tt.run_for(@ui.move_most_ms)
      tt.leave()
      tt.draw()
      let key = tt.all(Button, label=back)
      let sheet = tt.all(Dialog, label=title)
      let body = tt.words().filter(fn(x) { x.0 == "下一步的内容" })
      guard key.length() == 1 && sheet.length() == 1 && body.length() == 1 else {
        @halt.saying("\{at}: missing back/sheet/body: \{key.length()} \{sheet.length()} \{body.length()}")
      }
      let (kx, ky, kw, kh) = key[0].rect
      let (sx, sy, _, _) = sheet[0].rect
      let (_, bx, _, _, _, _) = body[0]
      assert_eq((kw.round(), kh.round()), (36.0, 36.0), msg=at)
      assert_eq(((kx - sx).round(), (ky - sy).round()), (24.0, 24.0), msg=at)
      assert_eq((kx - bx).round(), 0.0, msg=at)
      let cf = tt.corner_faults()
      let af = tt.audit().filter(fn(f) { !f.contains("「打开」") })
      let cfs = cf.join("; ")
      let afs = af.join("; ")
      assert_eq(cf, [], msg="\{at}: \{cfs}")
      assert_eq(af, [], msg="\{at}: \{afs}")
    }
  }
}

///|
test "a stepped centred dialog's back key stands concentric with its top-left corner and flush with body words" {
  for title in ["申请钥匙", head_long_title] {
    let open = fn(_ : Anchor) {
      panel_nodes("第一步", from=Unanchored, fn(v, close) {
        button_node(v, fn() { "下一步" }, fn() {
          close()
          panel_nodes(title, from=Unanchored, fn(v2, _) {
            v2.box(fn(b) { words_node(b, fn() { "下一步的内容" }, fn() { dialog_lead }) |> ignore }) |> ignore
          })
        })
        |> ignore
      })
    }
    presenters_reset()
    let back = t("common.back")
    let tt = @ui.Tester::new(
      fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
      tree=presented_tree(presenting_view(open)),
      w=1200.0,
      h=800.0,
      platform=0,
    )
    tt.check_looks(false)
    tt.draw()
    tt.tap_text("打开")
    tt.run_for(@ui.move_most_ms)
    tt.tap_text("下一步")
    tt.run_for(@ui.move_most_ms)
    tt.leave()
    tt.draw()
    let key = tt.all(Button, label=back)
    let dlg = tt.all(Dialog, label=title)
    let body = tt.words().filter(fn(x) { x.0 == "下一步的内容" })
    guard key.length() == 1 && dlg.length() == 1 && body.length() == 1 else {
      @halt.saying("\{title}: missing back/dialog/body: \{key.length()} \{dlg.length()} \{body.length()}")
    }
    let (kx, ky, kw, kh) = key[0].rect
    let (dx, dy, _, _) = dlg[0].rect
    let (_, bx, _, _, _, _) = body[0]
    let cf = tt.corner_faults()
    let cfs = cf.join("; ")
    assert_eq((kw.round(), kh.round()), (36.0, 36.0), msg=title)
    assert_eq(((kx - dx).round(), (ky - dy).round()), (24.0, 24.0), msg=title)
    assert_eq((kx - bx).round(), 0.0, msg=title)
    assert_eq(cf, [], msg="\{title}: \{cfs}")
  }
}
