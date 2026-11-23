// The headless toolbar (@headless.toolbar, Toolbar::item), under `window` (window_test.mbt) so zero-draw is enforced.

///|
fn tb_focus(t : @ui.Tester) -> String {
  t.focused().map(fn(s) { s.label }).unwrap_or("none")
}

///|
test "toolbar: read out a Toolbar by its label; single roving Tab stop; ←/→, Home/End wrap and skip disabled items; focus_stop works" {
  let tb_ref : Ref[@headless.Toolbar?] = Ref(None)
  let bold = @signals.signal(false)
  let t = window(fn(root) {
    let side = fn(name : String) {
      @headless.button(root, fn() { name }, fn(_) {  }, fn(v, _) {
        v.width(Is(Some(40.0))).height(Is(Some(28.0))) |> ignore
      })
      |> ignore
    }
    side("前")
    @headless.toolbar(root, fn() { "格式" }, fn(v, tb) {
      tb_ref.val = Some(tb)
      v.row(Is(true)) |> ignore
      // Button via in_node=true
      let b1 = @headless.button(v, fn() { "撤销" }, fn(_) {  }, fn(n, _) {
        n.width(Is(Some(50.0))).height(Is(Some(28.0))) |> ignore
      })
      tb.item(b1, fn(_) {  }, in_node=true) |> ignore
      // Disabled button
      let b2 = @headless.button(v, fn() { "重做" }, fn(_) {  }, disabled=fn() { true }, fn(n, _) {
        n.width(Is(Some(50.0))).height(Is(Some(28.0))) |> ignore
      })
      tb.item(b2, fn(_) {  }, disabled=fn() { true }, in_node=true) |> ignore
      // Toggle button registered as preferred
      let tg = @headless.toggle(v, Button, fn() { "加粗" }, fn() { bold.get() }, fn(to) { bold.set(to) }, fn(n, _) {
        n.width(Is(Some(50.0))).height(Is(Some(28.0))) |> ignore
      })
      tb.item(tg, fn(_) {  }, preferred=fn() { true }, in_node=true) |> ignore
      // Button built inside Toolbar::item slot (in_node=false)
      tb.item(v, fn(slot) {
        @headless.button(slot, fn() { "斜体" }, fn(_) {  }, in_node=true, fn(n, _) {
          n.width(Is(Some(50.0))).height(Is(Some(28.0))) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
    side("后")
  })
  assert_true(t.query(Toolbar, label="格式") is Some(_))
  let tb = tb_ref.val.unwrap()
  assert_eq(tb.disabled(), false)
  // Tab from "前" lands on preferred "加粗"; second Tab exits straight to "后"
  t.act(Button, Focus, label="前")
  t.tab()
  let tab_in = tb_focus(t)
  t.tab()
  let tab_out = tb_focus(t)
  // focus_stop returns to "加粗"
  assert_true(tb.focus_stop())
  t.draw()
  let stop_at = tb_focus(t)
  // Right -> "斜体", Right wraps -> "撤销", Right skips disabled "重做" -> "加粗"
  t.key(@ui.key_code_right)
  let r1 = tb_focus(t)
  t.key(@ui.key_code_right)
  let r2 = tb_focus(t)
  t.key(@ui.key_code_right)
  let r3 = tb_focus(t)
  t.key(@ui.key_code_end)
  let at_end = tb_focus(t)
  t.key(@ui.key_code_home)
  let at_home = tb_focus(t)
  assert_eq(
    (tab_in, tab_out, stop_at, r1, r2, r3, at_end, at_home),
    ("加粗", "后", "加粗", "斜体", "撤销", "加粗", "斜体", "撤销"),
  )
}

///|
test "toolbar: rtl=true flips ←/→ and focus recovers when a focused toolbar item is removed" {
  let keys = @signals.signal(["一", "二", "三"])
  let t = window(fn(root) {
    @headless.toolbar(root, fn() { "工具条" }, rtl=true, fn(v, tb) {
      v.row(Is(true)) |> ignore
      v.each(fn() { keys.get() }, fn(k) { k }, fn(slot, k) {
        let name = k.untracked()
        tb.item(slot, in_node=true, fn(n) {
          @headless.button(n, fn() { name }, fn(_) {  }, in_node=true, fn(b, _) {
            b.width(Is(Some(50.0))).height(Is(Some(28.0))) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
    })
    |> ignore
  })
  t.act(Button, Focus, label="一")
  // RTL: Left moves forward ("一" -> "二")
  t.key(@ui.key_code_left)
  let after_left = tb_focus(t)
  // Removing focused "二" hands focus to "三"
  keys.set(["一", "三"])
  t.draw()
  let after_remove = tb_focus(t)
  assert_eq((after_left, after_remove), ("二", "三"))
}
