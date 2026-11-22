// A way-in page's button (way_in_button_node) across a phone's page (300 between its sides) at the system's size of
// words and at 1.3 (a phone's large size of words): one line in its 50 at 1; at 1.3 a label wider than the pill on two
// lines in its middle, the pill taller for them, never past its ends.

///|
/// Long words for a way-in button: as wide, in a test's letters (each Latin letter as wide as a test's text has it,
/// wider than the app's face's), as the invited landing's 「Create my own workspace instead」
/// (android-misc.invite.declineCreate) is in the app's face: within the pill's room at 1, wider than it at 1.3.
let way_in_long : String = "Create my own workspace"

///|
/// A phone's window 360 wide with a way-in button saying `label` across its page (300 between its sides of 30), the
/// system's size of words `fs`. The Tester, drawn.
fn way_in_case(label : String, fs : Double) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=360.0, h=300.0, platform=1)
  t.check_looks(false)
  set_dark(Some(false))
  @ui.set_tree_theme(ui_theme_now)
  if fs != 1.0 {
    t.set_font_scale(fs)
  }
  @ui.set_view_app(fn(root) {
    root.box(fn(page) {
      page.width(Is(Some(360.0))).padding(Is((sign_in_side_w, 20.0, sign_in_side_w, 20.0))) |> ignore
      way_in_button_node(page, fn() { label }, fn() {  }, solid=false) |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// Where the button named `label` is laid out and where its words are (x, y, w, h each), in `t`.
fn pill_and_words(
  t : @ui.Tester,
  label : String,
) -> ((Double, Double, Double, Double), (Double, Double, Double, Double)) raise {
  let all = t.all(Button, label~)
  guard all.length() == 1 else { fail("\{label}: \{all.length()} buttons") }
  guard t.words().iter().find_first(fn(w) { w.0 == label }) is Some(w) else { fail("\{label}: its words not drawn") }
  (all[0].rect, (w.1, w.2, w.3, w.4))
}

///|
test "a way-in button's long words: one line in its 50 at 1, two in a taller pill at 1.3, never past its ends" {
  for fs in [1.0, 1.3] {
    let t = way_in_case(way_in_long, fs)
    let ((bx, by, bw, bh), (wx, wy, ww, wh)) = pill_and_words(t, way_in_long)
    let at = "words at \{fs}: pill \{bx},\{by} \{bw}x\{bh}, words \{wx},\{wy} \{ww}x\{wh}"
    assert_eq(bw, 300.0, msg=at)
    if fs == 1.0 {
      assert_eq(bh, sign_in_button_h, msg=at)
    } else {
      assert_true(bh > sign_in_button_h, msg=at)
    }
    // (its words past where its round ends turn, within its top and foot, their two sides alike)
    assert_true(wx >= bx + sign_in_button_padx - 0.01, msg=at)
    assert_true(wx + ww <= bx + bw - sign_in_button_padx + 0.01, msg=at)
    assert_true(wy >= by - 0.01 && wy + wh <= by + bh + 0.01, msg=at)
    assert_true(((wx - bx) - (bx + bw - wx - ww)).abs() < 0.5, msg=at)
    assert_eq(t.audit(), [], msg=at)
  }
}

///|
test "a way-in button's short words: one line in its 50 at 1 and at 1.3, in its middle" {
  for fs in [1.0, 1.3] {
    let t = way_in_case("Sign in", fs)
    let ((bx, _, bw, bh), (wx, _, ww, _)) = pill_and_words(t, "Sign in")
    let at = "words at \{fs}"
    assert_true(bh >= sign_in_button_h, msg=at)
    assert_true(bh < sign_in_button_h * 1.3, msg=at)
    assert_true(((wx - bx) - (bx + bw - wx - ww)).abs() < 0.5, msg=at)
    assert_eq(t.audit(), [], msg=at)
  }
}
