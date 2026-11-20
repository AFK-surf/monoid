// A profile's failed allowance check is a card with its next action in the foot. Its button's words begin where the
// card's words do, while the button itself stands in the card's corner.

///|
test "an allowance failure's action starts on the card's words" {
  for (width, platform) in [(390.0, 2), (390.0, 0), (1280.0, 0)] {
    let t = setting_tester(Profile("ws1/st1", "cc"), width, platform~, mode="settings-profile-quota-failed")
    let (title_x, _, _, _) = t.rect_of("额度查询失败").unwrap()
    let (action_x, _, _, _) = t.rect_of("重新查询额度").unwrap()
    assert_true((action_x - title_x).abs() < 0.01, msg="width \{width}, platform \{platform}: title \{title_x}, action \{action_x}")
  }
}

///|
test "a missing local station's action starts on the card's words" {
  for width in [390.0, 1280.0] {
    let t = setting_tester(LocalStation, width, platform=0, host=fn(h) { h.set_app_said("local_station", "") })
    let (note_x, _, _, _) = t.rect_of("本机没有单独安装的 station").unwrap()
    let (action_x, _, _, _) = t.rect_of("添加这台 Mac").unwrap()
    assert_true((action_x - note_x).abs() < 0.01, msg="width \{width}: note \{note_x}, action \{action_x}")
  }
}

///|
test "a provider's link to verify the account is said whole, copied by its key and opened by its button" {
  let link = "https://accounts.google.com/v3/signin/continue?plt=AKgnsbvgpMGWUxHL-LdY6TaKwyqigcx13EZGzlKmZcGrDxrNDt57SPhlkbXKa1uIKydtd8wIqmUCw2x25ooo2v5G_JN2S8spn6C0rCAJWTFB47we5La_Ckx-UMLZpie3MBHPZkmLQIIq&continue=https://developers.google.com/gemini-code-assist/auth/auth_success_gemini&sarp=1&scc=1&flowName=GlifWebSignIn&authuser"
  assert_eq(trouble_link("Please verify:\n" + link + "\nthen again"), link)
  assert_eq(trouble_words("Please verify:\n" + link), "Please verify:")
  assert_eq(trouble_link("请求超时，已中止"), "")
  for (width, platform) in [(390.0, 2), (1280.0, 0)] {
    let at = "width \{width}, platform \{platform}"
    let t = setting_tester(Profile("ws1/st1", "cc"), width, platform~, mode="settings-profile-verify")
    assert_true(t.find("Please verify your account in your browser to continue:") is Some(_), msg=at)
    assert_true(t.find(link) is Some(_), msg=at)
    let (x, y) = t.find_last("打开链接").unwrap()
    t.tap(x, y)
    t.frame()
    assert_eq(t.opened(), [link], msg=at)
    let (cx, cy) = t.find_last("复制").unwrap()
    t.tap(cx, cy)
    t.frame()
    assert_eq(t.clipboard(), link, msg=at)
  }
}
