// Tests for headless trigger_menu (@, /, # detection, UTF-16 safety, apply_trigger, and TriggerMenu coordinator).
// Tree test uses `window` (window_test.mbt) so zero-draw/zero-layout is enforced.

///|
let tm_rules : Array[@headless.TriggerRule] = [
  { trigger: "@", allow_spaces: false, start_only: false },
  { trigger: "/", allow_spaces: false, start_only: true },
  { trigger: "#", allow_spaces: true, start_only: false },
]

///|
test "detect_trigger: @, /, # boundary rules, start_only, allow_spaces, and newline stop" {
  // Start of text
  assert_eq(
    @headless.detect_trigger("@ali", 4, tm_rules),
    Some({ trigger: "@", query: "ali", start: 0, end: 4 }),
  )
  // After space
  assert_eq(
    @headless.detect_trigger("hi @bob", 7, tm_rules),
    Some({ trigger: "@", query: "bob", start: 3, end: 7 }),
  )
  // Mid-word email does not trigger
  assert_eq(@headless.detect_trigger("a@b", 3, tm_rules), None)
  // start_only: `/` works at text start and line start, not after space mid-line
  assert_eq(
    @headless.detect_trigger("/help", 5, tm_rules),
    Some({ trigger: "/", query: "help", start: 0, end: 5 }),
  )
  assert_eq(
    @headless.detect_trigger("line1\n/cmd", 10, tm_rules),
    Some({ trigger: "/", query: "cmd", start: 6, end: 10 }),
  )
  assert_eq(@headless.detect_trigger("say /cmd", 8, tm_rules), None)
  // allow_spaces=false stops on space; allow_spaces=true allows spaces in query
  assert_eq(@headless.detect_trigger("@alice bob", 10, tm_rules), None)
  assert_eq(
    @headless.detect_trigger("see #my issue", 13, tm_rules),
    Some({ trigger: "#", query: "my issue", start: 4, end: 13 }),
  )
  // Newline breaks scanning even with allow_spaces=true
  assert_eq(@headless.detect_trigger("#one\ntwo", 8, tm_rules), None)
}

///|
test "detect_trigger and apply_trigger: UTF-16 safety with Chinese and emoji" {
  // "😀" is 2 UTF-16 code units; "😀 @张伟" has length 2 + 1 + 1 + 2 = 6
  let text = "😀 @张伟"
  assert_eq(text.length(), 6)
  let m = @headless.detect_trigger(text, 6, tm_rules)
  assert_eq(m, Some({ trigger: "@", query: "张伟", start: 3, end: 6 }))
  let (applied, cur) = @headless.apply_trigger(text, m.unwrap(), "@ZhangWei")
  assert_eq((applied, cur), ("😀 @ZhangWei ", 13))
  // Without trailing space and preserving suffix
  let text2 = "你好 @al 世界"
  let m2 = @headless.detect_trigger(text2, 6, tm_rules).unwrap()
  let (applied2, cur2) = @headless.apply_trigger(text2, m2, "@alice", trailing_space=false)
  assert_eq((applied2, cur2), ("你好 @alice 世界", 9))
}

///|
test "TriggerMenu: active navigation, choose, and Escape dismiss suppression until cursor leaves or text changes" {
  let menu : @headless.TriggerMenu[String] = @headless.TriggerMenu::new(tm_rules)
  let items = ["alice", "alex", "alfred"]
  let m1 = menu.update("hi @al", 6, items)
  assert_true(m1 is Some(_))
  assert_eq((menu.is_open(), menu.active(), menu.active_index()), (true, Some("alice"), 0))
  // Move next and wrap
  assert_eq(menu.move_next(), Some("alex"))
  assert_eq(menu.move_next(), Some("alfred"))
  assert_eq(menu.move_next(), Some("alice"))
  // Move prev wraps to end
  assert_eq(menu.move_prev(), Some("alfred"))
  // Dismiss at start=3: same text & same start stays suppressed
  menu.dismiss()
  assert_eq((menu.is_open(), menu.active()), (false, None))
  assert_eq(menu.update("hi @al", 6, items), None)
  assert_eq(menu.update("hi @al", 5, items), None)
  // Changing text reopens even at the same start=3
  assert_true(menu.update("hi @ale", 7, ["alex"]) is Some(_))
  assert_eq(menu.active(), Some("alex"))
  // Dismiss again, then move cursor away from trigger and back -> reopens
  menu.dismiss()
  assert_eq(menu.update("hi @ale", 2, items), None)
  assert_true(menu.update("hi @ale", 7, ["alex"]) is Some(_))
  // Choose returns active item and closes
  assert_eq(menu.choose(), Some("alex"))
  assert_eq((menu.is_open(), menu.active()), (false, None))
}

///|
test "TriggerMenu wired in a headless window obeys zero-draw" {
  let menu : @headless.TriggerMenu[String] = @headless.TriggerMenu::new(tm_rules)
  let _ = menu.update("@a", 2, ["alpha", "beta"])
  let t = window(fn(root) {
    root.box(fn(v) {
      v.width(Is(Some(160.0))).height(Is(Some(32.0))).ground(Is(c_rest)) |> ignore
      v.says(By(fn() { Some(@view.said(Group, label=menu.active().unwrap_or(""))) })) |> ignore
    })
    |> ignore
  })
  assert_eq(t.get(Group, label="alpha").label, "alpha")
  let _ = menu.move_next()
  t.draw()
  assert_eq(t.get(Group, label="beta").label, "beta")
}
