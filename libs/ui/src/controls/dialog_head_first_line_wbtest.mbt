// A dialog's head whose title takes two lines: its close button at the head's end, and a step's back key before its
// title, stand on the title's first line where they stood by a title of one line, never centred on the two lines
// (head_line_drop, dialog_step_head, panel_step_line, sheet_title_row: 「这种不应该对标题居中」). Measured as how far a
// button's middle is from the middle of its title's first line, with a title of one line and of two.

///|
/// How far the middle of the button called `button` stands under the middle of the first line of `title` in what `open`
/// presents on a window `w` wide (中屏 a dialog, 小屏 a sheet), opened by 打开.
fn head_button_off(open : (Anchor) -> Unit, title : String, button : String, w? : Double = 1200.0) -> (Double, Int) {
  presenters_reset()
  let t = @ui.Tester::new(
    fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
    tree=presented_tree(presenting_view(open)),
    w~,
    h=800.0,
    platform=0,
  )
  t.check_looks(false)
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
  for w in [1200.0, 390.0] {
    let (one, one_lines) = head_button_off(stepped("申请钥匙"), "申请钥匙", back, w~)
    let (two, two_lines) = head_button_off(stepped(head_long_title), head_long_title, back, w~)
    assert_eq((one_lines, two_lines >= 2), (1, true), msg="\{w}")
    assert_eq(two, one, msg="\{w}")
  }
}

///|
test "a sheet's step's back key stands concentric with the sheet's top corner, the title of one line or of two" {
  for title in ["申请钥匙", head_long_title] {
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
    tt.draw()
    tt.tap_text("打开")
    tt.run_for(@ui.move_most_ms)
    tt.leave()
    tt.draw()
    let key = tt.all(Button, label=back)
    let sheet = tt.all(Dialog, label=title)
    guard key.length() == 1 && sheet.length() == 1 else {
      @halt.saying("no back key or sheet: \{key.length()} \{sheet.length()}")
    }
    let (kx, ky, _, _) = key[0].rect
    let (sx, sy, _, _) = sheet[0].rect
    assert_eq(((kx - sx).round(), (ky - sy).round()), (26.0, 26.0), msg=title)
  }
}
