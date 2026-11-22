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
      }, button_at=JEnd)
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
