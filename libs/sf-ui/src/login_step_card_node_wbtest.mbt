// The library's login card and a request's card answered (login_step_card_node.mbt): its title with 取消 as the × on
// its first line, its lines, code and step pressed as they are given, 完成 coming in once a code is typed and sending
// it, a step left pressed as a whole, and an answer giving way to how it went in its place.

///|
/// A window with keyboard and mouse holding what `make` makes, its words at `scale` of their size.
fn u16_case(make : (@view.View) -> Unit, scale? : Double = 1.0, w? : Double = 600.0) -> @ui.Tester {
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w~, h=500.0, platform=0)
  t.check_looks(false)
  if scale != 1.0 {
    t.set_font_scale(scale)
  }
  @ui.set_view_app(fn(root) { make(root) })
  t.draw()
  t
}

///|
/// A step's button as a login's card is given one: `label`, solid or not, its other ways (`more`), `press`.
fn u16_step(label : String, solid : Bool, more : Array[MenuItem], press : () -> Unit) -> LoginStep {
  { key: "u16/" + label, label, solid, busy: false, external: false, more, last: true, press, told: None }
}

///|
test "a login's card: its × on its title's first line, cancelled as pressed; its code and its step pressed as given" {
  for scale in [1.0, 1.3] {
    let cancelled = @signals.signal(0)
    let pressed = @signals.signal(0)
    let copied = @signals.signal("")
    let t = u16_case(scale~, fn(root) {
      login_step_card_node(root, fn() { "GitHub CLI" }, cancel=(fn() { false }, fn() { cancelled.set(cancelled.get() + 1) }), fn(c) {
        login_active_node(c, fn() { false }, fn(x, _) {
          login_lines_node(
            x,
            fn() { [{ words: "在 github.com 上输入这个码", red: false, busy: false, last: false }] },
            fn() { "8F2C-41DA" },
            fn() {
              Some(u16_step("复制并打开", true, [menu_item_of("复制链接", fn() {  })], fn() { pressed.set(pressed.get() + 1) }))
            },
            fn(code) { copied.set(code) },
          )
        })
      })
    })
    let at = "words ×\{scale}"
    let (_, ty, _, _) = t.rect_of("GitHub CLI").unwrap()
    let x = t.query(Button, label="web-main.logins.cancelWhat").unwrap().rect
    // (the × in the card's top corner, over the title's first line, not under it)
    assert_true(x.1 <= ty, msg="\{at}: × at \{x.1}, title at \{ty}")
    t.tap(x.0 + x.2 / 2.0, x.1 + x.3 / 2.0)
    t.run_for(@ui.move_most_ms)
    assert_eq(cancelled.get(), 1)
    t.tap_text("复制并打开")
    t.run_for(@ui.move_most_ms)
    assert_eq(pressed.get(), 1)
    t.tap_text("8F2C-41DA")
    t.run_for(@ui.move_most_ms)
    assert_eq(copied.get(), "8F2C-41DA")
    assert_true(t.query(Button, label="common.login.otherWays") is Some(_), msg="\{at}: the ⋯ beside the step")
    let faults = t.audit()
    assert_true(faults.is_empty(), msg="\{at}: \{faults.join("\n")}")
  }
}

///|
test "a login's card with nothing to cancel here: no ×, its line last; ended, one line alone" {
  let t = u16_case(fn(root) {
    root.box(fn(col) {
      col.gap(Is(12.0)) |> ignore
      login_step_card_node(col, fn() { "AWS CLI" }, fn(c) {
        login_said_node(c, fn() { { words: "请在工作站上完成登录", red: false, busy: false, last: true } })
      })
      login_ended_node(col, fn() { "gcloud · 登录失败" }, fn() { true })
    })
    |> ignore
  })
  assert_true(t.query(Button, label="web-main.logins.cancelWhat") is None)
  assert_true(t.rect_of("请在工作站上完成登录") is Some(_))
  assert_true(t.rect_of("gcloud · 登录失败") is Some(_))
  assert_eq(t.audit(), [])
}

///|
test "a code pasted back: 完成 comes in once a code is typed, Enter sends it and it turns while it is sent" {
  let field = @ui.Field::new()
  let sent = @signals.signal("")
  let t = u16_case(fn(root) {
    login_step_card_node(root, fn() { "Claude Code" }, fn(c) {
      login_active_node(c, fn() { true }, fn(x, _) {
        login_paste_node(
          x,
          fn() { { words: "把页面给出的码粘贴回来", red: false, busy: false, last: false } },
          fn() { { ..u16_step("打开登录页", false, [], fn() {  }), external: true, last: false } },
          field,
          fn() { sent.get() != "" },
          fn(code) { sent.set(code) },
        )
      })
    })
  })
  assert_true(t.query(Button, label="web-main.logins.finish") is None, msg="nothing typed: no 完成")
  t.tap_text("web-main.logins.pasteCode")
  t.type_text("abc123 ")
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="web-main.logins.finish") is Some(_), msg="typed: 完成")
  t.key(@ui.key_code_enter)
  t.run_for(@ui.move_most_ms)
  assert_eq(sent.get(), "abc123")
  // (sent: 完成 stays, turning, taking no press)
  assert_true(t.query(Button, label="web-main.logins.finish") is Some(_), msg="sent: 完成 still there")
  // (the field's words 12 in, 完成 4 from its end, concentric with its corner: the card's look, cardPaste's, as the
  // app's was)
  let faults = t.audit().filter(fn(f) { !(f.has_prefix("rule 4:") && f.contains("web-main.logins.finish")) })
  assert_true(faults.is_empty(), msg=faults.join("\n"))
}

///|
test "a step left: the whole card pressed where it goes somewhere, a card alone where it goes nowhere" {
  let went = @signals.signal(0)
  let t = u16_case(fn(root) {
    step_card_node(root, fn() { "在手机上配对" }, fn() { "打开无线调试" }, fn() { Some(fn() { went.set(went.get() + 1) }) })
    step_card_node(root, fn() { "不能共享调试" }, fn() { "" }, fn() { None })
  })
  assert_true(t.query(Button, label="在手机上配对") is Some(_))
  assert_true(t.query(Button, label="不能共享调试") is None)
  t.tap_text("在手机上配对")
  t.run_for(@ui.move_most_ms)
  assert_eq(went.get(), 1)
  assert_eq(t.audit(), [])
}

///|
test "answered in place: the answer gives way to how it went where it stood, the card no taller; the line opens it again" {
  let ended : @signals.Signal[(Bool, String)?] = @signals.signal(None)
  let opened = @signals.signal(0)
  let t = u16_case(fn(root) {
    ask_card_node(root, fn(k) {
      ask_words_node(k, fn() { "允许调试你的手机" }, fn() { "" }) |> ignore
      answered_in_place_node(k, fn() { ended.get().map(fn(e) { (e.0, [@ui.span(e.1)]) }) }, fn(a) {
        ask_buttons_node(a, fn(f) {
          button_node(f, fn() { "允许" }, fn() { ended.set(Some((true, "已允许 · 1 小时"))) }, tone=Primary, card_words=true) |> ignore
          button_node(f, fn() { "拒绝" }, fn() { ended.set(Some((false, "已拒绝"))) }, tone=Ghost, card_words=true) |> ignore
        })
        |> ignore
      })
    })
    |> ignore
    ask_outcome_node(root, fn() { true }, fn() { [@ui.span("已允许使用 GitHub 令牌")] }, fn() { false }, history=Some(fn(_) {
      opened.set(opened.get() + 1)
    }))
  })
  let (_, _, _, before) = t.rect_of("允许调试你的手机").unwrap()
  let (_, ay, _, _) = t.rect_of("允许").unwrap()
  t.click(Button, label="允许")
  t.run_for(answered_fade_ms * 2.0 + @ui.move_most_ms)
  assert_true(ended.get() is Some(_), msg="允许 pressed")
  let words = t.words().map(fn(w) { w.0 })
  guard t.rect_of("已允许 · 1 小时") is Some((_, wy, _, _)) else {
    fail("how it went shown: \{words.join(" | ")}")
  }
  assert_true(wy >= ay - 1.0, msg="how it went where the answer was: \{wy} against \{ay}")
  assert_eq(t.rect_of("允许调试你的手机").map(fn(r) { r.3 }), Some(before))
  // (the answer gone takes no press)
  t.tap_text("拒绝")
  t.run_for(@ui.move_most_ms)
  assert_true(t.rect_of("已拒绝") is None, msg="拒绝 taken after the answer")
  t.tap_text("已允许使用 GitHub 令牌")
  t.run_for(@ui.move_most_ms)
  assert_eq(opened.get(), 1)
  assert_eq(t.audit(), [])
}
