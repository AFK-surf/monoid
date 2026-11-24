// 账号 (account.mbt) alone, at each width, with a finger and with a mouse: who is signed in, where, another added;
// its picture changed; signing out and deleting asked first.

///|
test "账号, at each width and with either hand: who it is, where it is signed in, another to add; deleting asked first" {
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(Me, w, platform~)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("lin@example.com") is Some(_), msg=at)
    assert_true(t.find("Google 账号") is Some(_), msg=at)
    assert_true(t.find("Chrome · macOS") is Some(_), msg=at)
    assert_true(t.find("登录另一个账号") is Some(_), msg=at)
    assert_false(@sf.presenting(), msg=at)
    scrolled_to(t, w, "注销")
    let (x, y) = t.find_last("注销").unwrap()
    t.tap(x, y)
    t.frame()
    assert_true(@sf.presenting(), msg=at)
    assert_true(t.find("注销后无法恢复") is Some(_), msg=at)
  }
}

///|
/// The fixture's account (lin@example.com, sub u1) signed in with Apple: its sub as Apple's sign-in makes it (apple_…).
fn apple_signed_in(s : Source) -> Source {
  let apple = fn(a : Json) -> Json {
    match a {
      Object(m) if m.get("sub") is Some(String("u1")) => {
        let o = m.copy()
        o["sub"] = Json::string("apple_001234.abcd")
        Json::object(o)
      }
      _ => a
    }
  }
  {
    ..s,
    topic_read: fn(name, params) {
      let got = s.topic(name, params).get().snapshot()
      match got.value {
        Some(Array(accounts)) if name == "accounts" => { ..got, value: Some(Json::array(accounts.map(apple))) }
        Some(Array(entries)) if name == "workspaces" =>
          {
            ..got,
            value: Some(
              Json::array(
                entries.map(fn(e) {
                  match e {
                    Object(m) => {
                      let o = m.copy()
                      if m.get("account") is Some(acc) {
                        o["account"] = apple(acc)
                      }
                      Json::object(o)
                    }
                    _ => e
                  }
                }),
              ),
            ),
          }
        _ => got
      }
    },
  }
}

///|
test "账号 signed in with Apple, at each width and with either hand: Apple 账号, not Google's" {
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(Me, w, platform~, over=apple_signed_in)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("lin@example.com") is Some(_), msg=at)
    assert_true(t.find("Apple 账号") is Some(_), msg=at)
    assert_true(t.find("Google 账号") is None, msg=at)
  }
}

///|
/// 账号 over the made-up core, its account's `workspaces` entry saying it shows a picture of its own where `own`, the
/// calls made of the core kept in `calls` (`account.*` answered at once), `others` signed in on this device as well.
fn own_picture_tester(
  w : Double,
  platform : Int,
  own : Bool,
  calls : Array[(String, Json)],
  others? : Array[Json] = [],
) -> @ui.Tester {
  setting_tester(Me, w, platform~, over=fn(s) {
    {
      ..s,
      topic_read: fn(name, params) {
        let got = s.topic(name, params).get().snapshot()
        match got.value {
          Some(Array(accounts)) if name == "accounts" => { ..got, value: Some(Json::array(accounts + others)) }
          Some(Array(entries)) if name == "workspaces" && own =>
            {
              ..got,
              value: Some(
                Json::array(
                  entries.map(fn(e) {
                    match e {
                      Object(m) => {
                        let o = m.copy()
                        o["ownPicture"] = Json::boolean(true)
                        Json::object(o)
                      }
                      _ => e
                    }
                  }),
                ),
              ),
            }
          _ => got
        }
      },
      call: fn(name, params, done) {
        calls.push((name, params))
        if name.has_prefix("account.") {
          done(Ok(obj([])))
        } else {
          (s.call)(name, params, done)
        }
      },
    }
  })
}

///|
test "账号's picture, at each width and with either hand: its face pressed asks the system's photos at once, one picked made its face and put up; no rows of their own for it" {
  for case in page_cases {
    let (w, platform) = case
    let at = "\{w} platform \{platform}"
    let calls : Array[(String, Json)] = []
    let t = own_picture_tester(w, platform, false, calls)
    assert_true(t.find("更换头像") is None, msg=at)
    assert_true(t.find("恢复默认头像") is None, msg=at)
    // pressed: the system's photo picker asked; called off, nothing put up
    t.picks([])
    t.click(Button, label="更换头像")
    t.frame()
    assert_false(@sf.presenting(), msg=at)
    assert_eq(t.pick_asks().length(), 1, msg=at)
    assert_true(t.pick_asks()[0] == Photos, msg=at)
    assert_true(calls.iter().all(fn(c) { !c.0.has_prefix("account.") }), msg=at)
    // pressed again, a picture picked: read, made its face and put up as its own
    t.picks([("face.jpg", b"\xFF\xD8\xFF\xE0")])
    t.click(Button, label="更换头像")
    t.frame()
    assert_eq(t.pick_asks().length(), 2, msg=at)
    let put = calls.filter(fn(c) { c.0 == "account.setPicture" })
    assert_eq(put.length(), 1, msg=at)
    assert_eq(@sfbase.text(Some(put[0].1), "account"), "u1", msg=at)
    assert_true(@sfbase.text(Some(put[0].1), "picture").has_prefix("data:image/jpeg;base64,"), msg=at)
    assert_eq(@sfbase.toast_words(), "已更换头像", msg=at)
  }
}

///|
test "账号's picture of its own, at each width and with either hand: its face pressed offers another or its sign-in's again" {
  for case in page_cases {
    let (w, platform) = case
    let at = "\{w} platform \{platform}"
    let calls : Array[(String, Json)] = []
    let t = own_picture_tester(w, platform, true, calls)
    assert_true(t.find("恢复默认头像") is None, msg=at)
    t.click(Button, label="更换头像")
    t.frame()
    assert_true(@sf.presenting(), msg=at)
    assert_eq(t.pick_asks().length(), 0, msg=at)
    assert_true(t.find("更换头像") is Some(_), msg=at)
    let (x, y) = t.find("恢复默认头像").unwrap()
    t.tap(x, y)
    t.frame()
    let removed = calls.filter(fn(c) { c.0 == "account.removePicture" })
    assert_eq(removed.length(), 1, msg=at)
    assert_eq(@sfbase.text(Some(removed[0].1), "account"), "u1", msg=at)
    assert_eq(@sfbase.toast_words(), "已恢复默认头像", msg=at)
    assert_eq(t.pick_asks().length(), 0, msg=at)
  }
}

///|
test "账号's other accounts, at each width and with either hand: each one's face pressed changes its own picture" {
  for case in page_cases {
    let (w, platform) = case
    let at = "\{w} platform \{platform}"
    let calls : Array[(String, Json)] = []
    let t = own_picture_tester(w, platform, false, calls, others=[{ "sub": "u2", "email": "lin@work.example", "name": "" }])
    let faces = t.all(Button, label="更换头像")
    assert_eq(faces.length(), 2, msg=at)
    t.picks([("face.jpg", b"\xFF\xD8\xFF\xE0")])
    let (x, y, fw, fh) = faces[1].rect
    t.tap(x + fw / 2.0, y + fh / 2.0)
    t.frame()
    assert_eq(t.pick_asks().length(), 1, msg=at)
    let put = calls.filter(fn(c) { c.0 == "account.setPicture" })
    assert_eq(put.length(), 1, msg=at)
    assert_eq(@sfbase.text(Some(put[0].1), "account"), "u2", msg=at)
    assert_eq(@sfbase.toast_words(), "已更换头像", msg=at)
  }
}

///|
test "账号's devices, narrow: this one's 当前 whole on its line beside a name too long for it, the name cut short" {
  for platform in [2, 0] {
    let at = "platform \{platform}"
    let t = setting_tester(Me, 360.0, platform~, over=fn(s) {
      {
        ..s,
        topic_read: fn(name, params) {
          let got = s.topic(name, params).get().snapshot()
          match got.value {
            Some(Array(list)) if name == "loginSessions" => {
              let long = list.map(fn(d) {
                match d {
                  Object(m) if m.get("current") == Some(Json::boolean(true)) => {
                    let o = m.copy()
                    o["name"] = Json::string("youdid.wtf Android · OPPO PLP110 · Android 15")
                    Json::object(o)
                  }
                  _ => d
                }
              })
              { ..got, value: Some(Json::array(long)) }
            }
            _ => got
          }
        },
      }
    })
    scrolled_to(t, 360.0, "当前")
    // (one line of it, as high as one line of the rows' own small words: wrapped, 当 over 前, it was 36)
    let (_, _, _, pill_h) = t.rect_of("当前").unwrap()
    let (_, _, _, note_h) = t.rect_of("Chrome · macOS").unwrap()
    assert_true(pill_h <= note_h, msg="\{at}: 当前 \{pill_h} high")
  }
}

///|
test "账号's 退出登录 in its first row's end keeps the corner rule at each width and with either hand, lit too (a tablet's wide page under a finger: by the row's side, not moved)" {
  for case in page_cases + [(1194.0, 2)] {
    let (w, platform) = case
    let t = setting_tester(Me, w, platform~, h=834.0)
    let at = "\{w} platform \{platform}"
    assert_eq(t.corner_faults(), [], msg=at)
    assert_eq(t.lit_all_faults().filter(fn(f) { f.contains("退出登录") }), [], msg=at)
  }
}
