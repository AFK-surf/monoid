// Focus recovery (@headless.FocusRecovery) and RovingFocus removal recovery, under `window` (window_test.mbt) so
// zero-draw is enforced.

///|
fn fr_focus(t : @ui.Tester) -> String {
  t.focused().map(fn(s) { s.label }).unwrap_or("none")
}

///|
test "RovingFocus + FocusRecovery: removing focused middle item hands focus to next; removing focused last item hands focus to previous" {
  let items = @signals.signal(["一", "二", "三"])
  let rf = @headless.RovingFocus::new(axis=Vertical, roving=true)
  let t = window(fn(root) {
    root.each(fn() { items.get() }, fn(k) { k }, fn(slot, k) {
      let name = k.untracked()
      let b = @headless.button(slot, fn() { name }, fn(_) {  }, fn(v, _) {
        v.width(Is(Some(80.0))).height(Is(Some(28.0))) |> ignore
      })
      rf.add(b)
    })
  })
  // Focus middle item "二", then remove it -> focus lands on next ("三")
  t.act(Button, Focus, label="二")
  assert_eq(fr_focus(t), "二")
  items.set(["一", "三"])
  t.draw()
  let after_mid = fr_focus(t)
  // Focus is on last item "三", now remove it -> focus lands on previous ("一")
  items.set(["一"])
  t.draw()
  let after_last = fr_focus(t)
  assert_eq((after_mid, after_last), ("三", "一"))
}

///|
test "RovingFocus + FocusRecovery: when only disabled items remain, removing focused item skips disabled safely without crashing" {
  let items = @signals.signal(["甲", "乙", "丙"])
  let rf = @headless.RovingFocus::new(axis=Vertical, roving=true)
  let t = window(fn(root) {
    root.each(fn() { items.get() }, fn(k) { k }, fn(slot, k) {
      let name = k.untracked()
      let off = fn() { name != "乙" }
      let b = @headless.button(slot, fn() { name }, fn(_) {  }, disabled=off, fn(v, _) {
        v.width(Is(Some(80.0))).height(Is(Some(28.0))) |> ignore
      })
      rf.add(b, disabled=off)
    })
  })
  t.act(Button, Focus, label="乙")
  assert_eq(fr_focus(t), "乙")
  items.set(["甲", "丙"])
  t.draw()
  assert_eq(fr_focus(t), "none")
}

///|
test "RovingFocus + FocusRecovery: removing an unfocused item does not steal focus from another control" {
  let items = @signals.signal(["甲", "乙"])
  let rf = @headless.RovingFocus::new(axis=Vertical, roving=true)
  let t = window(fn(root) {
    @headless.button(root, fn() { "外部" }, fn(_) {  }, fn(v, _) {
      v.width(Is(Some(80.0))).height(Is(Some(28.0))) |> ignore
    })
    |> ignore
    root.each(fn() { items.get() }, fn(k) { k }, fn(slot, k) {
      let name = k.untracked()
      let b = @headless.button(slot, fn() { name }, fn(_) {  }, fn(v, _) {
        v.width(Is(Some(80.0))).height(Is(Some(28.0))) |> ignore
      })
      rf.add(b)
    })
  })
  t.act(Button, Focus, label="外部")
  items.set(["乙"])
  t.draw()
  assert_eq(fr_focus(t), "外部")
}

///|
test "FocusRecovery: disabling a focused tracked node hands focus to fallback" {
  let off_a = @signals.signal(false)
  let recovery = @headless.FocusRecovery::new()
  let b_ref : Ref[@view.View?] = Ref(None)
  let t = window(fn(root) {
    let a = @headless.button(root, fn() { "甲" }, fn(_) {  }, disabled=fn() { off_a.get() }, fn(v, _) {
      v.width(Is(Some(80.0))).height(Is(Some(28.0))) |> ignore
    })
    let b = @headless.button(root, fn() { "乙" }, fn(_) {  }, fn(v, _) {
      v.width(Is(Some(80.0))).height(Is(Some(28.0))) |> ignore
    })
    b_ref.val = Some(b)
    recovery.track(a, fn() { b_ref.val })
  })
  t.act(Button, Focus, label="甲")
  assert_eq(fr_focus(t), "甲")
  off_a.set(true)
  t.draw()
  assert_eq(fr_focus(t), "乙")
}
