// The headless text field's parts (@headless.TextField), under a look of the tests' own: its control read out a
// TextField called by the label and described by the description, or by the error while it is invalid, as that
// changes; the error read out a Status only while invalid and saying something; a press on the label giving the
// control the keys, shown, never while disabled (the control then taking no press and no focus, read out disabled); a
// control that says its own (`control_node`) given the keys the same. Each window is made by `window`
// (window_test.mbt), which holds that text_field.mbt draws and lays out nothing.

///|
/// What a field case keeps: its window and the field's states (the caller's).
struct TfCase {
  t : @ui.Tester
  invalid : @signals.Signal[Bool]
  error : @signals.Signal[String]
  off : @signals.Signal[Bool]
  value : @signals.Signal[String]
}

///|
/// A window: a button "别处", then the field "邮箱" (described "用于登录", its error as `error` says while `invalid`):
/// its label 200 by 20, its control 200 by 32 holding `value`, its description and its error each 200 by 16.
fn tf_case() -> TfCase raise {
  let invalid = @signals.signal(false)
  let error = @signals.signal("格式不对")
  let off = @signals.signal(false)
  let value = @signals.signal("a@b")
  let size = fn(v : @view.View, w : Double, h : Double) { v.width(Is(Some(w))).height(Is(Some(h))) |> ignore }
  let field = @headless.TextField::new(
    fn() { "邮箱" },
    description=fn() { "用于登录" },
    error=fn() { error.get() },
    invalid=fn() { invalid.get() },
    required=fn() { true },
    disabled=fn() { off.get() },
  )
  let t = window(fn(root) {
    @headless.button(root, fn() { "别处" }, fn(_) {  }, fn(v, _) { size(v, 80.0, 30.0) }) |> ignore
    field.label(root, fn(v) { size(v, 200.0, 20.0) }) |> ignore
    field.control(root, value=fn() { value.get() }, fn(v, f) {
      size(v, 200.0, 32.0)
      v.ground(By(fn() { if f.invalid() { c_pressed } else { c_rest } })) |> ignore
    })
    |> ignore
    field.description(root, fn(v) { size(v, 200.0, 16.0) }) |> ignore
    field.error(root, fn(v) { size(v, 200.0, 16.0) }) |> ignore
  })
  { t, invalid, error, off, value }
}

///|
/// What the control says now: its label, description and value, and whether it is read out disabled.
fn tf_control(t : @ui.Tester) -> (String, String, String, Bool) {
  let s = t.get(TextField, label="邮箱")
  (s.label, s.description, s.value, s.disabled)
}

///|
/// The middle of the label's node, as the label reads out.
fn tf_label_middle(t : @ui.Tester) -> (Double, Double) {
  let (x, y, w, h) = t.get(Text, label="邮箱").rect
  (x + w / 2.0, y + h / 2.0)
}

///|
test "a text field's control: read out a TextField by its label, described by its description, holding its value; invalid, described by its error, the error read out a Status as it comes; valid again, neither" {
  let k = tf_case()
  let valid = (tf_control(k.t), k.t.query(Status, label="格式不对") is Some(_))
  k.invalid.set(true)
  k.t.frame()
  let wrong = (tf_control(k.t), k.t.query(Status, label="格式不对") is Some(_))
  // (the error said anew: read out anew; said empty: the description again, no Status)
  k.error.set("缺少 @")
  k.value.set("ab")
  k.t.frame()
  let anew = (tf_control(k.t), k.t.query(Status, label="缺少 @") is Some(_))
  k.error.set("")
  k.t.frame()
  let empty = (tf_control(k.t).1, k.t.all(Status).length())
  k.error.set("格式不对")
  k.invalid.set(false)
  k.t.frame()
  let again = (tf_control(k.t).1, k.t.all(Status).length(), k.t.query(Text, label="用于登录") is Some(_))
  assert_eq(
    (valid, wrong, anew, empty, again),
    (
      (("邮箱", "用于登录", "a@b", false), false),
      (("邮箱", "格式不对", "a@b", false), true),
      (("邮箱", "缺少 @", "ab", false), true),
      ("用于登录", 0),
      ("用于登录", 0, true),
    ),
  )
}

///|
test "a press on a text field's label gives its control the keys, shown; disabled, the control takes no press and no focus and the label gives none" {
  let k = tf_case()
  k.t.act(Button, Focus, label="别处")
  let (lx, ly) = tf_label_middle(k.t)
  k.t.tap(lx, ly)
  let by_label = (focus_name(k.t), k.t.focused().map(fn(s) { s.focused }).unwrap_or(false))
  k.t.act(Button, Focus, label="别处")
  k.t.act(Text, Activate, label="邮箱")
  let by_activate = focus_name(k.t)
  k.off.set(true)
  k.t.frame()
  let lost = focus_name(k.t)
  k.t.act(Button, Focus, label="别处")
  k.t.tap(lx, ly)
  let off_label = focus_name(k.t)
  k.t.click(TextField, label="邮箱")
  assert_eq(
    (by_label, by_activate, lost == "邮箱", off_label == "邮箱", focus_name(k.t) == "邮箱", tf_control(k.t).3),
    (("邮箱", true), "邮箱", false, false, false, true),
  )
}

///|
test "a control that says its own (control_node): a press on the label gives it the keys; let go, the label gives none" {
  let shown = @signals.signal(true)
  let size = fn(v : @view.View, w : Double, h : Double) { v.width(Is(Some(w))).height(Is(Some(h))) |> ignore }
  let field = @headless.TextField::new(fn() { "备注" }, description=fn() { "选填" })
  let t = window(fn(root) {
    field.label(root, fn(v) { size(v, 200.0, 20.0) }) |> ignore
    root.show(fn() { shown.get() }, fn(s) {
      s.box(fn(v) {
        size(v, 200.0, 32.0)
        // (a control of the caller's own, saying its own name and description as its field gives them)
        v
        .presses(Is(true))
        .focusable(Is(true), keys=0)
        .says(By(fn() { Some(@view.said(TextField, label=field.label_text(), description=field.said_description())) }))
        |> ignore
        field.control_node(v)
      })
      |> ignore
    })
    |> ignore
  })
  t.act(Text, Activate, label="备注")
  let took = (focus_name(t), t.get(TextField, label="备注").description)
  shown.set(false)
  t.frame()
  t.run_for(@ui.move_most_ms)
  t.act(Text, Activate, label="备注")
  assert_eq((took, focus_name(t), t.get(Text, label="备注").disabled), (("备注", "选填"), "", true))
}
