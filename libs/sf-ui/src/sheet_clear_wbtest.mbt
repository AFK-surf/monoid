// A sheet from the foot (小屏's) between the system's bars down the window's sides (2026-11-17 「还是有问题」: an
// iPhone Duo on its side, the system's column of the app's tabs down its right side over the sheet of 归档「…」？, its
// 归档 under it).

///|
/// Where `words` stand, left and right, in tester `t` (rect_of's): none where they are not drawn.
fn sides_of(t : @ui.Tester, words : String) -> (Double, Double) {
  let (x, _, w, _) = t.rect_of(words).unwrap()
  (x, x + w)
}

///|
test "a sheet from the foot, the old frame's (a confirm) and the window's tree's (a panel of nodes), between the system's bars down the window's sides" {
  let (_, w, _) = phone
  let long = "归档后仍可在归档里找到。这个对话里的任务和等待中的事都会停下来，之后打开它还能接着做。"
  // (left, right: the system's column down the right side; a phone on its side, its cutout and its home indicator)
  for bars in [(0.0, 84.0), (40.0, 40.0)] {
    let (left, right) = bars
    for nodes in [false, true] {
      let tt = presenting_tester(phone, fn(from) {
        if nodes {
          panel_nodes("归档这个对话？", from~, fn(v, _) { words_node(v, fn() { long }, fn() { paragraph }) |> ignore })
        } else {
          confirm("归档这个对话？", long, "确认归档", fn() {  }, danger=true, from~)
        }
      })
      tt.post(@hostapi.system_channel, "{\"bars\":{\"top\":0,\"bottom\":21,\"left\":\{left},\"right\":\{right}}}")
      tt.run_for(@ui.move_most_ms)
      open_it(tt)
      assert_eq(presented_how, [AsSheet])
      let msg = "bars \{Repr(bars)}, of nodes \{nodes}"
      let seen = if nodes { [long] } else { [long, "确认归档", t("common.cancel")] }
      for words in seen {
        let (l, r) = sides_of(tt, words)
        assert_true(l >= left - 0.5 && r <= w - right + 0.5, msg="\{msg}: \{words} at \{Repr((l, r))}")
      }
    }
  }
}

///|
test "a dialog of the old frame's (one that goes in steps, a page's own): in the middle of the room the system's bars leave, no wider than it" {
  // (2026-11-17 「也看一下还有没有漏掉的」: @kit.dialog stood in the middle of the whole window, as wide as it less 32)
  let long = "这个对话框里的字很长，长到它会占满对话框的宽度，好看出对话框站在哪里、有多宽，是不是让开了系统栏。"
  // (window, then the bars: top, right, foot, left)
  for case in [((800.0, 600.0), (24.0, 84.0, 20.0, 0.0)), ((420.0, 600.0), (0.0, 60.0, 0.0, 60.0))] {
    let ((w, h), (top, right, foot, left)) = case
    let t = @ui.Tester::new(
      fn(c) { dialog(c, "d", true, "标题", fn() { c.text(long, style=paragraph) |> ignore }) |> ignore },
      w~,
      h~,
    )
    t.post(@hostapi.system_channel, "{\"bars\":{\"top\":\{top},\"bottom\":\{foot},\"left\":\{left},\"right\":\{right}}}")
    t.draw()
    t.run_for(t.rest_of("dialog/") - t.time())
    let (l, r) = sides_of(t, long)
    let msg = "\{Repr(case)}: words at \{Repr((l, r))}"
    assert_true(l >= left - 0.5 && r <= w - right + 0.5, msg~)
    assert_true(((l + r) / 2.0 - (left + (w - left - right) / 2.0)).abs() < 1.0, msg~)
    let (_, y, _, _) = t.rect_of("标题").unwrap()
    assert_true(y >= top, msg~)
  }
}
