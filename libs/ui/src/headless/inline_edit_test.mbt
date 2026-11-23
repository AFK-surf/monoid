// Tests for headless InlineEdit: preview activation (click, Enter, F2, double-click), editor Enter commit + refocus,
// Escape cancel + draft discard + refocus, blur commit/cancel, and disabled guard. All windows use `window`.

///|
fn ie_focus(t : @ui.Tester) -> String {
  t.focused().map(fn(s) { s.label }).unwrap_or("none")
}

///|
test "InlineEdit: Enter/F2 activate, Enter commits and returns focus, Escape cancels and discards draft" {
  let value = @signals.signal("原标题")
  let commits : Array[String] = []
  let cancels = Ref(0)
  let ie = @headless.InlineEdit::new(
    fn() { value.get() },
    fn(v) {
      commits.push(v)
      value.set(v)
    },
    on_cancel=fn() { cancels.val += 1 },
  )
  let t = window(fn(root) {
    root.box(fn(v) {
      v
      .width(Is(Some(160.0)))
      .height(Is(Some(32.0)))
      .ground(Is(c_rest))
      .says(By(fn() { Some(@view.said(Button, label="标题预览", value=value.get())) }))
      |> ignore
      ie.preview(v)
    })
    |> ignore
    root.box(fn(v) {
      v
      .width(Is(Some(160.0)))
      .height(Is(Some(32.0)))
      .ground(Is(c_rest))
      .says(By(fn() { Some(@view.said(TextField, label="标题编辑", value=ie.draft())) }))
      |> ignore
      ie.editor(v)
    })
    |> ignore
  })
  // Focus preview and press Enter -> enters editing and focuses editor
  t.act(Button, Focus, label="标题预览")
  t.key(@ui.key_code_enter)
  let started = (ie.editing(), ie.draft(), ie_focus(t))
  // Modify draft and press Enter -> commits and returns focus to preview
  ie.set_draft("新标题")
  t.key(@ui.key_code_enter)
  let committed = (ie.editing(), value.get(), commits.copy(), ie_focus(t))
  // Press F2 on preview -> enters editing again
  t.key(@headless.inline_edit_key_f2)
  let f2_started = (ie.editing(), ie.draft(), ie_focus(t))
  // Modify draft and press Escape -> cancels, discards draft, returns focus to preview
  ie.set_draft("临时草稿")
  t.key(@ui.key_escape)
  let cancelled = (ie.editing(), ie.draft(), value.get(), cancels.val, ie_focus(t))
  assert_eq(started, (true, "原标题", "标题编辑"))
  assert_eq(committed, (false, "新标题", ["新标题"], "标题预览"))
  assert_eq(f2_started, (true, "新标题", "标题编辑"))
  assert_eq(cancelled, (false, "新标题", "新标题", 1, "标题预览"))
}

///|
test "InlineEdit: blur submits when submit_on_blur=true and cancels when submit_on_blur=false" {
  // Case 1: submit_on_blur=true
  let val1 = @signals.signal("A")
  let ie1 = @headless.InlineEdit::new(fn() { val1.get() }, fn(v) { val1.set(v) }, submit_on_blur=true)
  let t1 = window(fn(root) {
    root.box(fn(v) {
      v.width(Is(Some(100.0))).height(Is(Some(30.0))).says(Is(Some(@view.said(Button, label="预览")))) |> ignore
      ie1.preview(v)
    })
    |> ignore
    root.box(fn(v) {
      v.width(Is(Some(100.0))).height(Is(Some(30.0))).says(Is(Some(@view.said(TextField, label="编辑")))) |> ignore
      ie1.editor(v)
    })
    |> ignore
    @headless.button(root, fn() { "别处" }, fn(_) {  }, fn(v, _) {
      v.width(Is(Some(100.0))).height(Is(Some(30.0))) |> ignore
    })
    |> ignore
  })
  t1.click(Button, label="预览")
  ie1.set_draft("B")
  // Focus moves to "别处" -> blur commits "B"
  t1.act(Button, Focus, label="别处")
  assert_eq((ie1.editing(), val1.get(), ie_focus(t1)), (false, "B", "别处"))

  // Case 2: submit_on_blur=false
  let val2 = @signals.signal("X")
  let cancels2 = Ref(0)
  let ie2 = @headless.InlineEdit::new(
    fn() { val2.get() },
    fn(v) { val2.set(v) },
    on_cancel=fn() { cancels2.val += 1 },
    submit_on_blur=false,
  )
  let t2 = window(fn(root) {
    root.box(fn(v) {
      v.width(Is(Some(100.0))).height(Is(Some(30.0))).says(Is(Some(@view.said(Button, label="预览2")))) |> ignore
      ie2.preview(v)
    })
    |> ignore
    root.box(fn(v) {
      v.width(Is(Some(100.0))).height(Is(Some(30.0))).says(Is(Some(@view.said(TextField, label="编辑2")))) |> ignore
      ie2.editor(v)
    })
    |> ignore
    @headless.button(root, fn() { "别处2" }, fn(_) {  }, fn(v, _) {
      v.width(Is(Some(100.0))).height(Is(Some(30.0))) |> ignore
    })
    |> ignore
  })
  t2.click(Button, label="预览2")
  ie2.set_draft("Y")
  t2.act(Button, Focus, label="别处2")
  assert_eq((ie2.editing(), val2.get(), cancels2.val), (false, "X", 1))
}

///|
test "InlineEdit: double-click activation mode and disabled guard" {
  let off = @signals.signal(false)
  let ie = @headless.InlineEdit::new(fn() { "文本" }, fn(_) {  }, disabled=fn() { off.get() })
  let t = window(fn(root) {
    root.box(fn(v) {
      v
      .width(Is(Some(120.0)))
      .height(Is(Some(32.0)))
      .ground(Is(c_rest))
      .says(Is(Some(@view.said(Button, label="双击编辑"))))
      |> ignore
      ie.preview(v, on_activate_double_click=true)
    })
    |> ignore
  })
  let (x, y, w, h) = t.get(Button, label="双击编辑").rect
  let (cx, cy) = (x + w / 2.0, y + h / 2.0)
  // Single tap does not enter editing
  t.tap(cx, cy)
  let after_one = ie.editing()
  // Second tap within double-click window activates
  t.tap(cx, cy)
  let after_two = ie.editing()
  ie.cancel()
  // Disabled blocks start
  off.set(true)
  t.draw()
  ie.start()
  assert_eq((after_one, after_two, ie.editing()), (false, true, false))
}
