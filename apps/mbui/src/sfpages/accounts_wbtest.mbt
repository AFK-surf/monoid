// A profile's page (accounts.mbt) alone over the settings' fixture: Willow's
// (ws1/st1) Claude subscription and its API key, wide; ChatGPT 团队's.

///|
test "a profile's page, wide: who it is and whether it works, then its allowance and who uses it, sharing, settings" {
  let t = setting_tester(Profile("ws1/st1", "cc"), 1280.0)
  // its head: its name, what it is (the core's words), its last check
  assert_true(t.find("Claude 主账号") is Some(_))
  assert_true(t.find("订阅账号 · Ultra") is Some(_), msg="what it is")
  assert_true(t.find("订阅有效 · 5 分钟前检查") is Some(_), msg="its check in a line")
  // what is left of its allowance, a dial each, and who uses it in the same card
  assert_true(t.find("额度") is Some(_))
  assert_true(t.find("5 小时") is Some(_) && t.find("本周") is Some(_), msg="its windows")
  assert_true(t.find("星火助手") is Some(_))
  // whom it is shared with, and its settings
  scrolled_to(t, 1280.0, "分享给其他 station")
  assert_true(t.find("分享给其他 station") is Some(_), msg="sharing")
  scrolled_to(t, 1280.0, "默认 Fast")
  assert_true(t.find("默认 Fast") is Some(_))
}

///|
test "checking a Claude account does not ask for confirmation" {
  for (w, platform) in page_cases {
    let calls : Array[String] = []
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, over=fn(s) {
      { ..s, call: fn(name, params, done) {
          if name == "profile.check" || name == "profile.quota" { calls.push(name) }
          (s.call)(name, params, done)
        } }
    })
    t.click(Button, label="重新检查")
    t.frame()
    assert_eq(calls, ["profile.check", "profile.quota"])
    assert_false(@sf.presenting())
  }
}

///|
test "returning to a Claude account's open login page does not ask again" {
  for (w, platform) in page_cases {
    let calls : Array[String] = []
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, mode="settings-profile-login-station", over=fn(s) {
      fn with_open_screen(v : Json) -> Json {
        match v {
          Object(o) => {
            let copy = o.copy()
            for key, value in o { copy[key] = with_open_screen(value) }
            if text(Some(v), "state") == "needs_code" && flag(Some(v), "browser") {
              copy["screen"] = "browser:T1"
            }
            Json::object(copy)
          }
          Array(a) => Json::array(a.map(with_open_screen))
          _ => v
        }
      }
      { ..s,
        topic_read: fn(name, params) {
          let r = s.topic(name, params).get().snapshot()
          { ..r, value: r.value.map(with_open_screen) }
        },
        call: fn(name, params, done) {
          if name == "profile.loginBrowser" {
            calls.push(name)
            done(Ok({ "screen": "browser:T1" }))
          } else {
            (s.call)(name, params, done)
          }
        },
      }
    })
    t.click(Button, label="回到 Willow 的浏览器")
    t.frame()
    assert_eq(calls, ["profile.loginBrowser"])
    assert_false(@sf.presenting())
    assert_true(t.audit().is_empty())
  }
}

///|
test "a shared subscription's main switch and its station details remain usable at each width" {
  for case in page_cases {
    let (w, platform) = case
    let calls : Array[(String, Json)] = []
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, h=2400.0, over=fn(s) {
      { ..s, call: fn(name, params, done) {
          calls.push((name, params))
          if name == "profile.share" { done(Ok(obj([]))) } else { (s.call)(name, params, done) }
        } }
    })
    let at = "\{w} platform \{platform}"
    scrolled_to(t, w, "分享给其他 station")
    assert_eq(t.get(Switch, label="分享给其他 station").check, Some(On), msg=at)
    assert_true(t.find("所在 station") is Some(_) && t.find("可用的 station") is Some(_), msg=at)
    assert_true(t.find("将此账号迁移到其他 station") is Some(_), msg=at)
    assert_true(t.find("允许其他 station 上的对话使用此账号") is Some(_), msg=at)
    assert_true(t.find("选择哪些 station 可以使用此账号") is Some(_), msg=at)
    let boxes = t.boxes_held()
    let switch_title = boxes.filter(fn(b) { b.text == "分享给其他 station" })
    assert_eq(switch_title.length(), 1, msg=at)
    for title in ["所在 station", "可用的 station"] {
      let found = boxes.filter(fn(b) { b.text == title })
      assert_eq(found.length(), 1, msg="\{at}: \{title}")
      assert_eq(found[0].weight, 500, msg="\{at}: \{title}")
      assert_eq(found[0].color, switch_title[0].color, msg="\{at}: \{title} ink")
    }
    t.tap_text("所在 station")
    t.run_for(@motion.presence_in_ms)
    assert_true(t.find("移到哪台 station？") is Some(_), msg=at)
    @sf.presenters_reset()
    // (what was presented let go at once by hand, the test's way to close it: no signal of it, said)
    t.stepped()
    t.frame()
    t.tap_text("可用的 station")
    presented_in(t)
    assert_true(t.find("以后新加的 station 也能用") is Some(_), msg=at)
    assert_eq(t.get(Switch, label="全部 station").check, Some(On), msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    @sf.presenters_reset()
    // (what was presented let go at once by hand, the test's way to close it: no signal of it, said)
    t.stepped()
    t.frame()
    t.click(Switch, label="分享给其他 station")
    t.frame()
    let asked = calls.filter(fn(c) { c.0 == "profile.share" })
    assert_eq(asked.length(), 1, msg=at)
    assert_false(flag(Some(asked[0].1), "on"), msg=at)
  }
}

///|
test "which stations may use a share is said with the stations it was chosen among, so only theirs change" {
  let calls : Array[Json] = []
  let t = setting_tester(Profile("ws1/st1", "cc"), 1280.0, h=2400.0, over=fn(s) {
    { ..s, call: fn(name, params, done) {
        if name == "profile.share" {
          calls.push(params)
          done(Ok(obj([])))
        } else {
          (s.call)(name, params, done)
        }
      } }
  })
  scrolled_to(t, 1280.0, "可用的 station")
  let among = fn(p : Json) -> Array[String] {
    match field(Some(p), "among") {
      Some(Array(a)) => a.filter_map(fn(x) { if x is String(v) { Some(v) } else { None } })
      _ => []
    }
  }
  // Maple left out: the list of those ticked, and every one listed as what it was chosen among
  t.tap_text("可用的 station")
  t.run_for(@motion.presence_in_ms)
  t.click(Switch, label="Maple")
  t.frame()
  t.click(Button, label="完成")
  t.run_for(@motion.presence_out_ms)
  assert_eq(calls.length(), 1)
  assert_eq(field(Some(calls[0]), "allow"), Some(Json::array([Json::string("st1")])))
  assert_eq(among(calls[0]), ["st1", "st2"])
  // all of them ticked: no list, so the station keeps what was chosen of the others where it is in several workspaces
  t.tap_text("可用的 station")
  t.run_for(@motion.presence_in_ms)
  t.click(Button, label="完成")
  t.run_for(@motion.presence_out_ms)
  assert_eq(calls.length(), 2)
  assert_eq(field(Some(calls[1]), "allow"), None)
  assert_eq(among(calls[1]), ["st1", "st2"])
}

///|
test "a profile's workspace row shows its own mark, but no repeated initial without one" {
  for (w, platform) in page_cases {
    for (emoji, icon) in [("", ""), ("🌱", ""), ("", "glyph:star")] {
      let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, h=2400.0, over=fn(base) {
        {
          ..base,
          topic_read: fn(name, params) {
            if name == "memberships" {
              {
                value: Some({
                  "manages": true,
                  "workspaces": [{ "workspace": "ws2", "name": "个人", "home": false, "emoji": Json::string(emoji), "icon": Json::string(icon) }],
                }),
                error: None,
                version: 1,
              }
            } else {
              base.topic(name, params).get().snapshot()
            }
          },
        }
      })
      let at = "\{w} platform \{platform}, emoji \{emoji}, icon \{icon}"
      assert_true(t.get(Switch, label="个人").check is Some(_), msg=at)
      assert_true(t.boxes_held().filter(fn(b) { b.text == "个" }).is_empty(), msg=at)
      assert_eq(t.boxes_held().iter().any(fn(b) { b.text == "🌱" }), emoji != "", msg=at)
      assert_eq(drawn_names().iter().any(fn(n) { n.has_prefix("sf/pic/glyph/star") }), icon != "", msg=at)
    }
  }
}

///|
/// What the window's tree draws called by name now (View::drawn_as: a mark's glyph, sf/pic/glyph/NAME), each drawn
/// node's.
fn drawn_names() -> Array[String] {
  match @ui.view_tree() {
    Some(tree) => tree.drawn().map(fn(d) { tree.drawn_name(d.id) })
    None => []
  }
}

///|
test "a shared account's station rows explain what each row is for without per-station status rows" {
  for (w, platform) in page_cases {
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, h=2400.0)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("所在 station") is Some(_), msg=at)
    assert_true(t.find("将此账号迁移到其他 station") is Some(_), msg=at)
    assert_true(t.find("允许其他 station 上的对话使用此账号") is Some(_), msg=at)
    assert_true(t.find("选择哪些 station 可以使用此账号") is Some(_), msg=at)
    assert_true(t.query(Link, label="Maple") is None, msg="\{at}: per-station rows removed")
  }
}

///|
/// The fixture's Claude subscription before it is shared.
fn unshared_claude(s : Source) -> Source {
  fn without_share(v : Json) -> Json {
    match v {
      Object(o) => {
        let p = o.copy()
        for k, x in o {
          p[k] = without_share(x)
        }
        if o.get("id") == Some(Json::string("cc")) && o.contains("available") {
          p.remove("share")
        }
        Json::object(p)
      }
      Array(a) => Json::array(a.map(without_share))
      _ => v
    }
  }
  {
    ..s,
    topic_read: fn(name, params) {
      let v = s.topic(name, params).get().snapshot()
      match v.value {
        Some(x) => { ..v, value: Some(without_share(x)) }
        None => v
      }
    },
  }
}

///|
/// Replaces the stations list on a profile's sharing entry (for 1-station and 3-station share tests).
fn with_share_stations(s : Source, stations : Array[Json]) -> Source {
  fn shaped(v : Json) -> Json {
    match v {
      Object(o) => {
        let p = o.copy()
        for k, x in o {
          p[k] = shaped(x)
        }
        if o.contains("stations") && o.contains("members") {
          p["stations"] = Json::array(stations)
        }
        Json::object(p)
      }
      Array(a) => Json::array(a.map(shaped))
      _ => v
    }
  }
  {
    ..s,
    topic_read: fn(name, params) {
      let v = s.topic(name, params).get().snapshot()
      match v.value {
        Some(x) => { ..v, value: Some(shaped(x)) }
        None => v
      }
    },
  }
}

///|
test "sharing a Claude subscription asks about requests on the target stations before enabling it" {
  for case in page_cases {
    let (w, platform) = case
    let asked : Array[Json] = []
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, over=fn(base) {
      let s = unshared_claude(base)
      { ..s, call: fn(name, params, done) {
        if name == "profile.share" { asked.push(params) }
        (s.call)(name, params, done)
      } }
    })
    let at = "\{w} platform \{platform}"
    scrolled_to(t, w, "分享给其他 station")
    assert_eq(t.get(Switch, label="分享给其他 station").check, Some(Off), msg=at)
    t.click(Switch, label="分享给其他 station")
    t.frame()
    assert_true(@sf.presenting(), msg=at)
    assert_eq(asked.length(), 0, msg="\{at}: not shared before confirmation")
    presented_in(t)
    assert_true(t.find("其他 station 会借用此账号的登录凭证，在各自的机器上直接向 Claude 发送请求") is Some(_), msg=at)
    assert_true(t.find("请自行确保目标 station 能安全访问 Claude") is Some(_), msg=at)
    assert_eq(t.get(Switch, label="全部 station").check, Some(Off), msg=at)
    assert_eq(t.get(Switch, label="跟随工作区白名单").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="Maple").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="Willow").check, Some(On), msg=at)
    assert_true(t.get(Switch, label="Willow").disabled, msg=at)
    assert_false(t.get(Button, label="已了解，分享账号").disabled, msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    t.click(Button, label="取消")
    t.run_for(@motion.presence_out_ms)
    assert_eq(asked.length(), 0, msg="\{at}: cancellation does not share")
    assert_eq(t.get(Switch, label="分享给其他 station").check, Some(Off), msg=at)
    t.click(Switch, label="分享给其他 station")
    presented_in(t)
    assert_eq(t.get(Switch, label="跟随工作区白名单").check, Some(On), msg=at)
    assert_false(t.get(Button, label="已了解，分享账号").disabled, msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    t.click(Button, label="已了解，分享账号")
    t.frame()
    assert_eq(asked.length(), 1, msg="\{at}: shared after confirmation")
    assert_eq(text(Some(asked[0]), "station"), "ws1/st1", msg=at)
    assert_eq(text(Some(asked[0]), "id"), "cc", msg=at)
    assert_eq(field(Some(asked[0]), "on"), Some(Json::boolean(true)), msg=at)
    assert_eq(field(Some(asked[0]), "allowAuto"), Some(Json::boolean(true)), msg="\{at}: defaults to whitelist")
    assert_eq(field(Some(asked[0]), "allow"), None, msg=at)
    assert_eq(field(Some(asked[0]), "among"), None, msg="\{at}: initial share omits among")
    // Older station without shareAllowAuto: whitelist is disabled and off, requires picking before confirming
    let old_asked : Array[Json] = []
    let old = setting_tester(Profile("ws1/st1", "cc"), w, platform~, over=fn(base) {
      let s = with_share_auto(unshared_claude(base), auto_ok=false)
      { ..s, call: fn(name, params, done) {
        if name == "profile.share" { old_asked.push(params) }
        (s.call)(name, params, done)
      } }
    })
    scrolled_to(old, w, "分享给其他 station")
    old.click(Switch, label="分享给其他 station")
    presented_in(old)
    assert_eq(old.get(Switch, label="跟随工作区白名单").check, Some(Off), msg=at)
    assert_true(old.get(Switch, label="跟随工作区白名单").disabled, msg=at)
    assert_eq(old.get(Switch, label="Maple").check, Some(Off), msg=at)
    assert_true(old.get(Button, label="已了解，分享账号").disabled, msg=at)
    old.click(Switch, label="Maple")
    old.run_for(@ui.move_most_ms)
    assert_false(old.get(Button, label="已了解，分享账号").disabled, msg=at)
    old.click(Button, label="已了解，分享账号")
    old.frame()
    assert_eq(old_asked.length(), 1, msg=at)
    assert_eq(field(Some(old_asked[0]), "allowAuto"), None, msg=at)
  }
}

///|
test "sharing an account with three stations defaults to whitelist, supports partial pick and select-all toggle without among" {
  let three : Array[Json] = [
    { "id": "st1", "name": "Willow", "online": true },
    { "id": "st2", "name": "Maple", "online": true },
    { "id": "st3", "name": "Birch", "online": true },
  ]
  for case in page_cases {
    let (w, platform) = case
    let asked : Array[Json] = []
    // (tall enough that the dialog's rows, the whitelist's among them, need no scrolling)
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, h=2400.0, over=fn(base) {
      let s = with_share_stations(unshared_claude(base), three)
      { ..s, call: fn(name, params, done) {
        if name == "profile.share" {
          asked.push(params)
          done(Ok(obj([])))
        } else {
          (s.call)(name, params, done)
        }
      } }
    })
    let at = "\{w} platform \{platform}"
    scrolled_to(t, w, "分享给其他 station")
    t.click(Switch, label="分享给其他 station")
    presented_in(t)
    assert_eq(t.get(Switch, label="全部 station").check, Some(Off), msg=at)
    assert_eq(t.get(Switch, label="跟随工作区白名单").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="Maple").check, Some(Off), msg=at)
    assert_eq(t.get(Switch, label="Birch").check, Some(Off), msg=at)
    assert_true(t.find("以后新加的 station 不会自动加进来") is Some(_), msg=at)
    assert_false(t.get(Button, label="已了解，分享账号").disabled, msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    // Partial pick: only Maple (exits whitelist mode)
    t.click(Switch, label="Maple")
    t.run_for(@ui.move_most_ms)
    assert_eq(t.get(Switch, label="全部 station").check, Some(Off), msg=at)
    assert_eq(t.get(Switch, label="跟随工作区白名单").check, Some(Off), msg=at)
    assert_eq(t.get(Switch, label="Maple").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="Birch").check, Some(Off), msg=at)
    assert_false(t.get(Button, label="已了解，分享账号").disabled, msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    t.click(Button, label="已了解，分享账号")
    t.run_for(@motion.presence_out_ms)
    assert_eq(asked.length(), 1, msg=at)
    assert_eq(field(Some(asked[0]), "on"), Some(Json::boolean(true)), msg=at)
    assert_eq(field(Some(asked[0]), "allowAuto"), None, msg=at)
    assert_eq(field(Some(asked[0]), "allow"), Some(Json::array([Json::string("st1"), Json::string("st2")])), msg=at)
    assert_eq(field(Some(asked[0]), "among"), None, msg="\{at}: initial partial share omits among")
    // Re-open and test select-all toggle on -> off -> on
    t.click(Switch, label="分享给其他 station")
    presented_in(t)
    t.click(Switch, label="全部 station")
    t.run_for(@ui.move_most_ms)
    assert_eq(t.get(Switch, label="全部 station").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="跟随工作区白名单").check, Some(Off), msg=at)
    assert_eq(t.get(Switch, label="Maple").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="Birch").check, Some(On), msg=at)
    assert_true(t.find("以后新加的 station 也能用") is Some(_), msg=at)
    assert_false(t.get(Button, label="已了解，分享账号").disabled, msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    t.click(Switch, label="全部 station")
    t.frame()
    assert_eq(t.get(Switch, label="全部 station").check, Some(Off), msg=at)
    assert_eq(t.get(Switch, label="Maple").check, Some(Off), msg=at)
    assert_eq(t.get(Switch, label="Birch").check, Some(Off), msg=at)
    assert_true(t.find("以后新加的 station 不会自动加进来") is Some(_), msg=at)
    assert_true(t.get(Button, label="已了解，分享账号").disabled, msg=at)
    t.click(Switch, label="全部 station")
    t.frame()
    t.click(Button, label="已了解，分享账号")
    t.run_for(@motion.presence_out_ms)
    assert_eq(asked.length(), 2, msg=at)
    assert_eq(field(Some(asked[1]), "on"), Some(Json::boolean(true)), msg=at)
    assert_eq(field(Some(asked[1]), "allowAuto"), None, msg=at)
    assert_eq(field(Some(asked[1]), "allow"), None, msg="\{at}: select-all omits allow")
    assert_eq(field(Some(asked[1]), "among"), None, msg="\{at}: initial select-all omits among")
  }
}

///|
test "sharing an account with only its own station defaults to whitelist and requires turning on all stations if whitelist is turned off" {
  let one : Array[Json] = [{ "id": "st1", "name": "Willow", "online": true }]
  for case in page_cases {
    let (w, platform) = case
    let asked : Array[Json] = []
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, over=fn(base) {
      let s = with_share_stations(unshared_claude(base), one)
      { ..s, call: fn(name, params, done) {
        if name == "profile.share" {
          asked.push(params)
          done(Ok(obj([])))
        } else {
          (s.call)(name, params, done)
        }
      } }
    })
    let at = "\{w} platform \{platform}"
    scrolled_to(t, w, "分享给其他 station")
    t.click(Switch, label="分享给其他 station")
    presented_in(t)
    assert_eq(t.get(Switch, label="全部 station").check, Some(Off), msg=at)
    assert_eq(t.get(Switch, label="跟随工作区白名单").check, Some(On), msg=at)
    assert_false(t.get(Button, label="已了解，分享账号").disabled, msg=at)
    t.click(Switch, label="跟随工作区白名单")
    t.frame()
    assert_eq(t.get(Switch, label="跟随工作区白名单").check, Some(Off), msg=at)
    assert_true(t.get(Button, label="已了解，分享账号").disabled, msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    t.click(Switch, label="全部 station")
    t.run_for(@ui.move_most_ms)
    assert_eq(t.get(Switch, label="全部 station").check, Some(On), msg=at)
    assert_true(t.find("以后新加的 station 也能用") is Some(_), msg=at)
    assert_false(t.get(Button, label="已了解，分享账号").disabled, msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    t.click(Button, label="已了解，分享账号")
    t.run_for(@motion.presence_out_ms)
    assert_eq(asked.length(), 1, msg=at)
    assert_eq(field(Some(asked[0]), "on"), Some(Json::boolean(true)), msg=at)
    assert_eq(field(Some(asked[0]), "allowAuto"), None, msg=at)
    assert_eq(field(Some(asked[0]), "allow"), None, msg=at)
    assert_eq(field(Some(asked[0]), "among"), None, msg=at)
  }
}

///|
test "editing allowed stations supports toggling all stations off and picking a subset with among" {
  let three : Array[Json] = [
    { "id": "st1", "name": "Willow", "online": true },
    { "id": "st2", "name": "Maple", "online": true },
    { "id": "st3", "name": "Birch", "online": true },
  ]
  for case in page_cases {
    let (w, platform) = case
    let asked : Array[Json] = []
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, h=2400.0, over=fn(base) {
      let s = with_share_stations(base, three)
      { ..s, call: fn(name, params, done) {
        if name == "profile.share" {
          asked.push(params)
          done(Ok(obj([])))
        } else {
          (s.call)(name, params, done)
        }
      } }
    })
    let at = "\{w} platform \{platform}"
    scrolled_to(t, w, "可用的 station")
    t.tap_text("可用的 station")
    presented_in(t)
    assert_eq(t.get(Switch, label="全部 station").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="Maple").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="Birch").check, Some(On), msg=at)
    assert_false(t.get(Button, label="完成").disabled, msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    t.click(Switch, label="全部 station")
    t.frame()
    assert_eq(t.get(Switch, label="Maple").check, Some(Off), msg=at)
    assert_eq(t.get(Switch, label="Birch").check, Some(Off), msg=at)
    assert_false(t.get(Button, label="完成").disabled, msg="\{at}: edit mode keeps Done enabled")
    t.click(Switch, label="Maple")
    t.frame()
    assert_eq(t.get(Switch, label="全部 station").check, Some(Off), msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    t.click(Button, label="完成")
    t.run_for(@motion.presence_out_ms)
    assert_eq(asked.length(), 1, msg=at)
    assert_eq(field(Some(asked[0]), "allow"), Some(Json::array([Json::string("st1"), Json::string("st2")])), msg=at)
    assert_eq(
      field(Some(asked[0]), "among"),
      Some(Json::array([Json::string("st1"), Json::string("st2"), Json::string("st3")])),
      msg=at,
    )
  }
}

///|
test "sharing other accounts explains how they are used on target stations" {
  for profile in ["cx", "k2"] {
    for case in page_cases {
      let (w, platform) = case
      let asked : Array[Json] = []
      let t = setting_tester(Profile("ws1/st1", profile), w, platform~, over=fn(s) {
        { ..s, call: fn(name, params, done) {
          if name == "profile.share" { asked.push(params) }
          (s.call)(name, params, done)
        } }
      })
      let at = "\{profile} \{w} platform \{platform}"
      scrolled_to(t, w, "分享给其他 station")
      assert_eq(t.get(Switch, label="分享给其他 station").check, Some(Off), msg=at)
      t.click(Switch, label="分享给其他 station")
      t.frame()
      assert_true(@sf.presenting(), msg=at)
      assert_eq(asked.length(), 0, msg=at)
      presented_in(t)
      let body = if profile == "cx" { "借用此账号的登录凭证" } else { "账号配置及其中的密钥会同步" }
      assert_true(t.find(body) is Some(_), msg=at)
      assert_true(t.find("在各自的机器上发送请求") is Some(_), msg=at)
      assert_true(t.find("安全访问 Claude") is None, msg=at)
      assert_eq(t.get(Switch, label="全部 station").check, Some(Off), msg=at)
      assert_eq(t.get(Switch, label="跟随工作区白名单").check, Some(On), msg=at)
      assert_eq(t.get(Switch, label="Maple").check, Some(On), msg=at)
      assert_false(t.get(Button, label="分享账号").disabled, msg=at)
      assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
      t.click(Button, label="取消")
      t.run_for(@motion.presence_out_ms)
      assert_eq(asked.length(), 0, msg=at)
      assert_eq(t.get(Switch, label="分享给其他 station").check, Some(Off), msg=at)
      t.click(Switch, label="分享给其他 station")
      presented_in(t)
      assert_eq(t.get(Switch, label="跟随工作区白名单").check, Some(On), msg=at)
      assert_false(t.get(Button, label="分享账号").disabled, msg=at)
      assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
      t.click(Button, label="分享账号")
      t.frame()
      assert_eq(asked.length(), 1, msg=at)
      assert_eq(text(Some(asked[0]), "id"), profile, msg=at)
      assert_eq(field(Some(asked[0]), "on"), Some(Json::boolean(true)), msg=at)
      assert_eq(field(Some(asked[0]), "allowAuto"), Some(Json::boolean(true)), msg=at)
      assert_eq(field(Some(asked[0]), "among"), None, msg=at)
    }
  }
}

///|
test "stopping a share does not ask for confirmation" {
  let asked : Array[Json] = []
  let t = setting_tester(Profile("ws1/st1", "cc"), 1280.0, over=fn(s) {
    { ..s, call: fn(name, params, done) {
      if name == "profile.share" { asked.push(params) }
      (s.call)(name, params, done)
    } }
  })
  scrolled_to(t, 1280.0, "分享给其他 station")
  t.click(Switch, label="分享给其他 station")
  t.frame()
  assert_false(@sf.presenting())
  assert_eq(asked.length(), 1)
  assert_eq(field(Some(asked[0]), "on"), Some(Json::boolean(false)))
}

///|
test "a subscription's tier is shown on its page at every width" {
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~)
    assert_true(t.find("订阅账号 · Ultra") is Some(_), msg="tier at width \{w} platform \{platform}")
  }
}

///|
test "a key's profile's page, wide: its key masked, a new one asked for from its row" {
  let t = setting_tester(Profile("ws1/st1", "k2"), 1280.0)
  assert_true(t.find("备用 key") is Some(_))
  scrolled_to(t, 1280.0, "sk-…a41f")
  assert_true(t.find("sk-…a41f") is Some(_), msg="its key masked")
  // (the row's own: its trouble's 更换 key may be drawn above, out of sight)
  tap_words(t, "更换")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("新的 API key") is Some(_), msg="a new key asked for")
}

///|
test "a profile's page, wide: a profile one of the station's lists no more says so" {
  let t = setting_tester(Profile("ws1/st1", "gone"), 1280.0)
  assert_true(t.find("找不到 ID 为 gone 的 Profile") is Some(_))
}

// A profile's quota reset and its models over ChatGPT 团队: a reset used once asked, its
// models all listed, one named by hand and taken off again.

///|
test "a revoked Codex sign-in offers sign-in from the account check" {
  for (w, platform) in page_cases {
    let t = setting_tester(Profile("ws1/st1", "cx"), w, platform~, mode="settings-profile-quota-login")
    assert_true(t.find("需要登录") is Some(_))
    assert_true(t.find("ChatGPT 登录已失效，请重新登录") is Some(_))
    assert_true(t.find("订阅有效") is None, msg="the earlier account check must not contradict the expired login")
    assert_true(t.find("Willow 可用") is None, msg="this station must not be called usable after its login was refused")
    t.click(Button, label="登录")
    t.frame()
    assert_true(t.find("正在登录 ChatGPT") is Some(_), msg="the sign-in was started at width \{w}")
  }
}

///|
test "a profile's quota, a narrow page with a mouse: its resets left at the row's end; pressed, asks first, then uses one" {
  let t = setting_tester(Profile("ws1/st1", "cx"), 390.0)
  scrolled_to(t, 390.0, "剩 2 次")
  t.click(Link, label="额度重置")
  t.frame()
  assert_true(@sf.presenting(), msg="asked first")
  assert_true(t.find("重置额度？") is Some(_))
  assert_true(t.find("将使用「ChatGPT 团队」的 1 次额度重置，剩余 2 次") is Some(_))
  // (with a mouse: the web's confirm, come in)
  t.run_for(@motion.presence_in_ms)
  t.tap_text("使用一次重置")
  t.frame()
  t.frame()
  assert_true(t.find("剩 1 次") is Some(_))
}

///|
test "reset credits show their separate expiry times at every page width" {
  for (w, platform) in page_cases {
    let t = setting_tester(Profile("ws1/st1", "cx"), w, platform~, mode="settings-profile-quota-expiry")
    let note = "6 小时 35 分钟后、3 天 19 小时后到期"
    scrolled_to(t, w, note)
    assert_true(t.find(note) is Some(_), msg="reset expiries at width \{w}")
    assert_true(t.find("剩 2 次") is Some(_), msg="how many left, on their own, at width \{w}")
  }
}

///|
test "a subscription's resets of two kinds, a row each: what each gives back said, one usable only at a limit not offered, the other used by its kind" {
  for (w, platform) in page_cases {
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, mode="settings-profile-quota-kinds")
    scrolled_to(t, w, "Fable 重置")
    assert_true(t.find("5 小时重置") is Some(_), msg="the 5-hour kind at width \{w}")
    assert_true(t.find("立即恢复 5 小时额度 · 到达它能恢复的上限后才能用") is Some(_), msg="what it gives back, and why not now, at width \{w}")
    assert_true(t.find("把本周 Fable 用掉的额度还回每周额度 · 118 天后到期") is Some(_), msg="what the Fable one gives back at width \{w}")
    assert_true(t.find("剩 1 次") is Some(_), msg="how many left, on their own, at width \{w}")
  }
  let t = setting_tester(Profile("ws1/st1", "cc"), 390.0, mode="settings-profile-quota-kinds")
  scrolled_to(t, 390.0, "Fable 重置")
  assert_true(t.query(Link, label="5 小时重置") is None, msg="usable only at a limit: not offered")
  t.click(Link, label="Fable 重置")
  t.frame()
  assert_true(@sf.presenting(), msg="asked first")
  assert_true(t.find("将使用「Claude 主账号」的 1 次 Fable 重置：把本周 Fable 用掉的额度还回每周额度") is Some(_))
  t.run_for(@motion.presence_in_ms)
  t.click(Button, label="使用一次重置")
  // (its row closing its room on its way)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Link, label="Fable 重置") is None, msg="the Fable reset used, by its kind")
  assert_true(t.find("5 小时重置") is Some(_), msg="the other kind left")
}

///|
test "a profile's models, a narrow page with a mouse: how many in a row; all of them in a panel, each a box to star; one named by hand added there, then taken off by its ×" {
  let t = setting_tester(Profile("ws1/st1", "cx"), 390.0)
  scrolled_to(t, 390.0, "可用模型")
  assert_true(t.find("12 个模型") is Some(_), msg="how many")
  assert_true(t.find("勾选常用模型，或按名称添加自定义模型") is Some(_), msg="what clicking it does")
  assert_true(t.find("GPT-6-MINI") is None, msg="not laid out on the page")
  t.tap_text("可用模型")
  t.run_for(@motion.presence_in_ms)
  assert_true(@sf.presenting(), msg="a panel")
  assert_true(t.find("GPT-6-MINI") is Some(_), msg="every one it runs")
  assert_true(t.query(Checkbox, label="喜欢 GPT-6-MINI") is Some(_), msg="its box")
  assert_true(t.query(Button, label="移除 GPT-6-MINI") is None, msg="one its provider lists: not taken off")
  // a name typed, then 添加
  t.tap_text("按名称添加模型")
  t.type_text("my-model")
  t.frame()
  // (添加 alone: the field's placeholder has the word too)
  tap_words(t, "添加")
  t.frame()
  t.frame()
  assert_true(t.query(Button, label="移除 MY-MODEL") is Some(_), msg="the model named, among the rest")
  // its × takes it off again (the sheet grown to hold it, on its way from as tall as it was: at rest)
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="移除 MY-MODEL")
  // (its row closing its room on its way)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="移除 MY-MODEL") is None, msg="taken off")
}

///|
test "a profile model's id appears beside the option the pointer is over" {
  let t = setting_tester(Profile("ws1/st1", "cc"), 1280.0)
  scrolled_to(t, 1280.0, "可用模型")
  t.tap_text("可用模型")
  t.run_for(@motion.presence_in_ms)
  for (name, id) in [("Opus 5.5", "claude-opus-5-5"), ("Sonnet 5", "claude-sonnet-5")] {
    // (its name on its box's row in the panel, not where the page under it says it)
    let (bx, by, _, bh) = t.get(Checkbox, label="喜欢 \{name}").rect
    let (_, x, y, w, h, _) = t.words().filter(fn(e) { e.0 == name && e.1 > bx && (e.2 + e.4 / 2.0 - (by + bh / 2.0)).abs() < 2.0 })[0]
    t.move_to(x + w / 2.0, y + h / 2.0)
    t.run_for(@sf.tip_delay_ms + @motion.presence_in_ms)
    let tip = t.get(Tooltip, label=id).rect
    let gap = tip.0 - (x + w)
    assert_true(gap >= 0.0 && gap <= 24.0, msg="\{name}: tip is directly to its right, gap \{gap}")
    let middle = tip.1 + tip.3 / 2.0 - (y + h / 2.0)
    assert_true(middle >= -1.0 && middle <= 1.0, msg="\{name}: tip is on the same row, offset \{middle}")
  }
}

///|
/// The fixture's Claude subscription as android 0.1.6389 showed one (2026-10-31): named by its long address, four
/// models on, its last 7 days' figures large.
fn long_profile(s : Source) -> Source {
  fn shaped(v : Json) -> Json {
    match v {
      Object(o) if o.get("id") == Some(Json::string("cc")) && o.contains("available") => {
        let p = o.copy()
        let ms : Array[Json] = ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5", "claude-haiku-5"]
        p["name"] = "claude5@jimmfly.example.com"
        p["models"] = Json::array(ms)
        p["modelsText"] = "4 个模型"
        p["available"] = Json::array(ms)
        p["names"] = { "claude-fable-5-1": "Fable 5.1", "claude-opus-5-5": "Opus 5.5", "claude-sonnet-5": "Sonnet 5", "claude-haiku-5": "Haiku 5" }
        p["series"] = [{ "name": "Claude", "models": Json::array(ms) }]
        Json::object(p)
      }
      Object(o) => {
        let p = o.copy()
        for k, x in o {
          p[k] = shaped(x)
        }
        if o.contains("lists") && o.contains("tiles") {
          // (in place of the fixture's own accounts)
          let lists = match o.get("lists") { Some(Array(a)) => a.filter(fn(l) {
                match l {
                  Object(m) => !(m.get("key") is Some(String("profiles")))
                  _ => true
                }
              }); _ => [] }
          lists.push({ "key": "profiles", "items": [{ "key": "ws1/st1/cc", "costText": "$1,735", "shareText": "64%", "callsText": "2.2 万", "tokensText": "49.7 亿", "topModel": "最多 Opus 5.5" }] })
          p["lists"] = Json::array(lists)
        }
        Json::object(p)
      }
      Array(a) => Json::array(a.map(shaped))
      _ => v
    }
  }
  {
    ..s,
    topic_read: fn(name, params) {
      let v = s.topic(name, params).get().snapshot()
      match v.value {
        Some(x) => { ..v, value: Some(shaped(x)) }
        None => v
      }
    },
  }
}

///|
test "a profile's page on a phone: its long name and how many models it runs, nothing squeezed" {
  for w in [326.0, 390.0] {
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform=2, over=long_profile, h=2400.0)
    // (its switches' words, beside their switches, are another's)
    let faults = t.squeeze_faults().filter(fn(f) { !f.contains("for what shares their row") })
    assert_eq(faults, [], msg=w.to_string() + faults.join("; "))
    assert_true(t.find("近 7 天") is None, msg="\{w}: usage removed from profile page")
    assert_true(t.find("4 个模型") is Some(_), msg="\{w}: 4 个模型")
  }
}

///|
test "a Devin profile's models panel asks Fusion pairs on demand, switches lead model chips, deduplicates ticked ones, and syncs pick.like" {
  let calls : Array[(String, Json)] = []
  let existing_uid = "fusion-gpt-6-sol-sidekick-claude-sonnet-5-5-medium"
  let fusion_catalog : Json = {
    "sides": [
      { "id": "swe-2-medium", "name": "SWE-2 · 中", "maker": { "id": "devin", "name": "Cognition" } },
      { "id": "claude-sonnet-5-5-medium", "name": "Sonnet 5.5 · 中", "maker": { "id": "anthropic", "name": "Anthropic" } },
    ],
    "leads": [
      {
        "id": "claude-opus-5-5",
        "name": "Opus 5.5",
        "maker": { "id": "anthropic", "name": "Anthropic" },
        "sides": [0],
      },
      {
        "id": "gpt-6-sol",
        "name": "GPT-6 Sol",
        "maker": { "id": "openai", "name": "OpenAI" },
        "sides": [0, 1],
      },
    ],
  }
  let fusion_profile = fn(s : Source) -> Source {
    fn shaped(v : Json) -> Json {
      match v {
        Object(o) if o.get("id") == Some(Json::string("cc")) && o.contains("available") => {
          let p = o.copy()
          p["runtime"] = "devin"
          p["models"] = ["gemini-4-carbon", existing_uid]
          p["named"] = [existing_uid]
          p["added"] = [existing_uid]
          p["modelsText"] = "2 个模型"
          p["available"] = ["gemini-4-carbon", existing_uid]
          p["names"] = {
            "gemini-4-carbon": "Gemini 4 Carbon",
            "fusion-gpt-6-sol-sidekick-claude-sonnet-5-5-medium": "GPT-6 Sol + Sonnet 5.5 (中)",
          }
          p["series"] = [
            { "name": "Gemini", "models": ["gemini-4-carbon"] },
            { "name": "Sol", "models": [existing_uid] },
          ]
          Json::object(p)
        }
        Object(o) => {
          let p = o.copy()
          for k, x in o {
            p[k] = shaped(x)
          }
          Json::object(p)
        }
        Array(a) => Json::array(a.map(shaped))
        _ => v
      }
    }
    fn shaped_pick(v : Json) -> Json {
      match v {
        Object(o) => {
          let p = o.copy()
          let opts = match o.get("options") {
            Some(Array(a)) => a.copy()
            _ => []
          }
          opts.push({ "model": existing_uid, "ids": [existing_uid], "liked": true })
          p["options"] = Json::array(opts)
          Json::object(p)
        }
        _ => v
      }
    }
    {
      ..s,
      topic_read: fn(name, params) {
        let v = s.topic(name, params).get().snapshot()
        match v.value {
          Some(x) => { ..v, value: Some(if name == "pick" { shaped_pick(x) } else { shaped(x) }) }
          None => v
        }
      },
      call: fn(name, params, done) {
        calls.push((name, params))
        if name == "profile.fusion" {
          done(Ok({ "fusion": fusion_catalog }))
        } else {
          done(Ok(obj([])))
        }
      },
    }
  }
  let t = setting_tester(Profile("ws1/st1", "cc"), 1280.0, over=fusion_profile)
  assert_eq(calls.length(), 0)
  scrolled_to(t, 1280.0, "可用模型")
  t.tap_text("可用模型")
  t.run_for(@motion.presence_in_ms)
  assert_eq(calls.map(fn(x) { x.0 }), ["profile.fusion"])
  assert_true(t.find("Fusion 组合") is Some(_))
  // Already-ticked Fusion pair from another lead (`gpt-6-sol`) is shown in `Fusion 组合`, not duplicated in top series.
  assert_true(t.find("GPT-6 Sol + Sonnet 5.5 (中)") is None)
  assert_true(t.find("GPT-6 Sol + Sonnet 5.5 · 中") is Some(_))
  assert_true(t.query(Checkbox, label="SWE-2 · 中") is Some(_))
  // Unchecking the already-ticked & liked pair removes it from `models` and clears `pick.like`.
  t.click(Checkbox, label="GPT-6 Sol + Sonnet 5.5 · 中")
  t.frame()
  assert_eq(calls.map(fn(x) { x.0 }), ["profile.fusion", "profile.put", "pick.like"])
  assert_true(!calls[1].1.stringify().contains(existing_uid), msg="profile.put drops \{existing_uid}: \{calls[1].1.stringify()}")
  assert_true(calls[2].1.stringify().contains("\"liked\":false"), msg="pick.like clears \{existing_uid}: \{calls[2].1.stringify()}")
  // Switching lead model chip to `GPT-6 Sol` and checking a sidekick saves it and stars it.
  // First verify Lead group is a single RadioGroup supporting arrow keys and sticky selection.
  assert_true(t.query(RadioGroup, label=@sf.t("web-pages.profiles.fusionLead")) is Some(_))
  assert_eq(t.get(Radio, label="Opus 5.5").check, Some(@view.Check::On))
  // Re-pressing already-selected lead keeps it selected.
  t.click(Radio, label="Opus 5.5")
  t.frame()
  assert_eq(t.get(Radio, label="Opus 5.5").check, Some(@view.Check::On))
  // Focusing Lead radio and pressing Right arrow moves to `GPT-6 Sol`, Left arrow moves back.
  t.act(Radio, Focus, label="Opus 5.5")
  t.frame()
  t.key(@ui.key_code_right)
  t.frame()
  assert_eq(t.get(Radio, label="GPT-6 Sol").check, Some(@view.Check::On))
  assert_eq(t.focused().map(fn(s) { s.label }), Some("GPT-6 Sol"))
  t.key(@ui.key_code_left)
  t.frame()
  assert_eq(t.get(Radio, label="Opus 5.5").check, Some(@view.Check::On))
  // Click `GPT-6 Sol` and check/uncheck a sidekick Checkbox chip.
  t.click(Radio, label="GPT-6 Sol")
  t.frame()
  assert_true(t.query(Checkbox, label="SWE-2 · 中") is Some(_))
  t.click(Checkbox, label="SWE-2 · 中")
  t.frame()
  assert_eq(calls.map(fn(x) { x.0 }), ["profile.fusion", "profile.put", "pick.like", "profile.put", "pick.like"])
  let uid = "fusion-gpt-6-sol-sidekick-swe-2-medium"
  assert_true(calls[3].1.stringify().contains(uid), msg="profile.put saves \{uid}: \{calls[3].1.stringify()}")
  assert_true(calls[4].1.stringify().contains("\"liked\":true"), msg="pick.like likes \{uid}: \{calls[4].1.stringify()}")
}

///|
test "profile page shows non-quota explanations and intermediate checking states" {
  // 1. Subscription with unsupported quota (e.g. Devin / Kimi Code) and no usedBy still shows the quota card and detail.
  let t_unsupported = setting_tester(Profile("ws1/st1", "cc"), 1280.0, over=fn(s) {
    fn shaped(v : Json) -> Json {
      match v {
        Object(o) if o.get("id") == Some(Json::string("cc")) => {
          let p = o.copy()
          p["quota"] = {
            "state": "unsupported",
            "detail": "Devin 不向 station 提供套餐用量，请在 app.devin.ai 的 Usage 页查看",
            "windows": [],
          }
          Json::object(p)
        }
        Object(o) if o.get("connects") is Some(_) => {
          let p = o.copy()
          for k, x in o {
            p[k] = shaped(x)
          }
          p["connects"] = Json::array([])
          p["presets"] = Json::array([])
          Json::object(p)
        }
        Object(o) => {
          let p = o.copy()
          for k, x in o {
            p[k] = shaped(x)
          }
          Json::object(p)
        }
        Array(a) => Json::array(a.map(shaped))
        _ => v
      }
    }
    {
      ..s,
      topic_read: fn(name, params) {
        let r = s.topic(name, params).get().snapshot()
        { ..r, value: r.value.map(shaped) }
      },
    }
  })
  assert_true(t_unsupported.find("额度") is Some(_))
  assert_true(t_unsupported.find("Devin 不向 station 提供套餐用量，请在 app.devin.ai 的 Usage 页查看") is Some(_))

  // 2. Subscription with unchecked quota (quota: null) shows 尚未查询额度, modelsReading shows 正在读取, and clicking 重新检查 dispatches both profile.check and profile.quota.
  let calls : Array[String] = []
  let t_unchecked = setting_tester(Profile("ws1/st1", "cc"), 1280.0, h=2400.0, over=fn(s) {
    fn shaped(v : Json) -> Json {
      match v {
        Object(o) if o.get("id") == Some(Json::string("cc")) => {
          let p = o.copy()
          p["quota"] = Json::null()
          p["available"] = Json::array([])
          p["modelsReading"] = Json::boolean(true)
          Json::object(p)
        }
        Object(o) => {
          let p = o.copy()
          for k, x in o {
            p[k] = shaped(x)
          }
          Json::object(p)
        }
        Array(a) => Json::array(a.map(shaped))
        _ => v
      }
    }
    {
      ..s,
      topic_read: fn(name, params) {
        let r = s.topic(name, params).get().snapshot()
        { ..r, value: r.value.map(shaped) }
      },
      call: fn(name, params, done) {
        if name == "profile.check" || name == "profile.quota" {
          calls.push(name)
        }
        (s.call)(name, params, done)
      },
    }
  })
  assert_true(t_unchecked.find("订阅账号 · Ultra") is Some(_))
  assert_true(t_unchecked.find("尚未查询额度") is Some(_))
  assert_true(t_unchecked.find("正在读取") is Some(_))
  t_unchecked.click(Button, label="重新检查")
  t_unchecked.frame()
  assert_eq(calls, ["profile.check", "profile.quota"])

  // 3. Plain API key with check.state == "ok" and quota.detail shows its capabilities in the facts line and quota.detail in the header state line without a quota card.
  let t_key = setting_tester(Profile("ws1/st1", "k2"), 1280.0, over=fn(s) {
    fn shaped(v : Json) -> Json {
      match v {
        Object(o) if o.get("id") == Some(Json::string("k2")) => {
          let p = o.copy()
          p["checkTone"] = Json::string("green")
          p["checkText"] = Json::string("可用")
          p["checkLine"] = Json::string("8 个模型")
          p["check"] = { "state": "ok", "time": { "checkedAt": { "ago": "5 分钟前" } } }
          p["quota"] = { "state": "unsupported", "detail": "按量计费，无额度上限", "windows": [] }
          Json::object(p)
        }
        Object(o) => {
          let p = o.copy()
          for k, x in o {
            p[k] = shaped(x)
          }
          Json::object(p)
        }
        Array(a) => Json::array(a.map(shaped))
        _ => v
      }
    }
    {
      ..s,
      topic_read: fn(name, params) {
        let r = s.topic(name, params).get().snapshot()
        { ..r, value: r.value.map(shaped) }
      },
    }
  })
  assert_true(t_key.find("API key · Anthropic") is Some(_))
  assert_true(t_key.find("可用于：") is Some(_))
  assert_true(t_key.find("Claude Code") is Some(_))
  assert_true(t_key.find("按量计费，无额度上限 · 5 分钟前检查") is Some(_))
  assert_true(t_key.boxes_held().filter(fn(b) { b.text == "额度" }).is_empty())
}

///|
test "a wide profile head aligns its 32 mark with the name's first line and starts the lines below at the mark's left edge" {
  let t = setting_tester(Profile("ws1/st1", "cc"), 1280.0)
  assert_eq(t.first_line_faults(), [])
  assert_eq(t.line_start_faults(), [])
  let name_word = t.words().filter(fn(w) { w.0 == "Claude 主账号" })[0]
  let facts_word = t.words().filter(fn(w) { w.0 == "订阅账号 · Ultra" })[0]
  let uses_word = t.words().filter(fn(w) { w.0 == "可用于：" })[0]
  let state_word = t.words().filter(fn(w) { w.0.contains("订阅有效") })[0]
  let mark_boxes = t.boxes_held().filter(fn(b) {
    (b.w - 32.0).abs() <= 0.5 &&
    (b.h - 32.0).abs() <= 0.5 &&
    b.x < name_word.1 &&
    (b.y - name_word.2).abs() < 20.0
  })
  assert_true(mark_boxes.length() > 0)
  let mark = mark_boxes[0]
  let mark_mid = mark.y + mark.h / 2.0
  let name_mid = name_word.2 + name_word.4 / 2.0
  assert_true(
    (mark_mid - name_mid).abs() <= 2.0,
    msg="mark_mid=\{mark_mid} name_mid=\{name_mid}",
  )
  assert_true(
    (facts_word.1 - mark.x).abs() <= 1.0,
    msg="facts_x=\{facts_word.1} mark_x=\{mark.x}",
  )
  assert_true(
    (uses_word.1 - mark.x).abs() <= 1.0,
    msg="uses_x=\{uses_word.1} mark_x=\{mark.x}",
  )
  assert_true(
    state_word.1 < name_word.1,
    msg="state_x=\{state_word.1} name_x=\{name_word.1}",
  )
}

///|
test "service profile hides model, fast, and env rows while keeping station controls and clean layout" {
  let svc : Json = {
    "id": "svc-gpu",
    "name": "GPU 节点账号",
    "email": "gpu@example.com",
    "runtime": null,
    "service": "fake-gpu",
    "runtimes": [],
    "access": { "kind": "service", "key": "", "service": "fake-gpu", "login": false },
    "usedBy": [],
    "loginCommand": "",
    "machine": false,
    "enabled": true,
    "fast": null,
    "check": { "state": "ok", "time": { "checkedAt": { "ago": "5 分钟前" } } },
    "login": null,
    "quota": null,
    "checkText": "可用",
    "checkTone": "green",
    "trouble": null,
    "makers": {},
    "names": {},
    "series": [],
    "modelsText": "尚未列出模型",
    "available": [],
    "added": [],
    "modelsReading": false,
    "uses": [],
    "canAddModel": false,
    "decisionOnly": false,
    "decisionModels": [],
    "share": null,
    "shareable": false,
    "workspaces": [],
    "kindText": "服务账号",
    "planText": "",
    "signInProvider": "",
    "checkLine": "连接正常",
  }
  let t = setting_tester(Profile("ws1/st1", "svc-gpu"), 1280.0, over=fn(s) {
    fn inject(v : Json) -> Json {
      match v {
        Object(o) => {
          let copy = o.copy()
          for k, val in o {
            copy[k] = if k == "profiles" && val is Array(arr) {
              Json::array(arr + [svc])
            } else {
              inject(val)
            }
          }
          Json::object(copy)
        }
        Array(a) => Json::array(a.map(inject))
        _ => v
      }
    }
    {
      ..s,
      topic_read: fn(name, params) {
        let r = s.topic(name, params).get().snapshot()
        { ..r, value: r.value.map(inject) }
      },
    }
  })
  assert_true(t.find("GPU 节点账号") is Some(_))
  assert_true(t.find("服务账号") is Some(_))
  assert_true(t.find("可用模型") is None, msg="service profile must not show availableModels")
  assert_true(t.find("默认 Fast") is None, msg="service profile must not show fast toggle")
  assert_true(t.find("编辑环境变量") is None, msg="service profile must not show env editor")
  scrolled_to(t, 1280.0, "分享给其他 station")
  assert_true(t.find("分享给其他 station") is Some(_), msg="service profile keeps sharing row")
  assert_eq(t.audit(), [])
}

///|
test "colab service profile shows CU credits, active VM note, and relogin on expired token" {
  let colab : Json = {
    "id": "colab-1",
    "name": "gpu@example.com",
    "email": "gpu@example.com",
    "runtime": null,
    "service": "colab",
    "runtimes": [],
    "access": { "kind": "service", "key": "", "service": "colab", "login": false },
    "usedBy": [],
    "loginCommand": "",
    "machine": false,
    "enabled": true,
    "fast": null,
    "check": { "state": "ok", "time": { "checkedAt": { "ago": "2 分钟前" } } },
    "login": null,
    "quota": {
      "state": "ok",
      "windows": [],
      "creditsText": "2,500 CU",
      "detail": "1 台运行中 · 10.05 CU/h",
      "time": { "checkedAt": { "ago": "2 分钟前" } },
    },
    "checkText": "可用",
    "checkTone": "green",
    "trouble": null,
    "makers": {},
    "names": {},
    "series": [],
    "modelsText": "尚未列出模型",
    "available": [],
    "added": [],
    "modelsReading": false,
    "uses": [],
    "providerName": "Google Colab",
    "providerMark": "colab",
    "canAddModel": false,
    "decisionOnly": false,
    "decisionModels": [],
    "share": null,
    "shareable": false,
    "workspaces": [],
    "kindText": "Google Colab",
    "planText": "",
    "signInProvider": "Google Colab",
    "checkLine": "已登录",
  }
  let t = setting_tester(Profile("ws1/st1", "colab-1"), 1280.0, over=fn(s) {
    fn inject(v : Json) -> Json {
      match v {
        Object(o) => {
          let copy = o.copy()
          for k, val in o {
            copy[k] = if k == "profiles" && val is Array(arr) {
              Json::array(arr + [colab])
            } else {
              inject(val)
            }
          }
          Json::object(copy)
        }
        Array(a) => Json::array(a.map(inject))
        _ => v
      }
    }
    {
      ..s,
      topic_read: fn(name, params) {
        let r = s.topic(name, params).get().snapshot()
        { ..r, value: r.value.map(inject) }
      },
    }
  })
  assert_true(t.find("gpu@example.com") is Some(_))
  assert_true(t.find("Google Colab") is Some(_))
  assert_true(t.find("2,500 CU") is Some(_), msg="colab profile must show CU balance")
  assert_true(t.find("1 台运行中 · 10.05 CU/h") is Some(_), msg="colab profile must show active VM note")
  assert_true(t.find("无可用额度信息") is None, msg="colab credits row must not fall back to no-quota row")
  assert_true(t.find("可用模型") is None)
  assert_true(t.find("默认 Fast") is None)
  assert_true(t.find("编辑环境变量") is None)
  assert_eq(t.audit(), [])

  // Token expired: check.state == "login" shows sign-in block with primary login button
  let expired : Json = {
    "id": "colab-exp",
    "name": "expired@example.com",
    "email": "expired@example.com",
    "runtime": null,
    "service": "colab",
    "runtimes": [],
    "access": { "kind": "service", "key": "", "service": "colab", "login": false },
    "usedBy": [],
    "loginCommand": "",
    "machine": false,
    "enabled": true,
    "fast": null,
    "check": { "state": "login", "time": { "checkedAt": { "ago": "刚刚" } } },
    "login": null,
    "quota": null,
    "checkText": "需要登录",
    "checkTone": "red",
    "trouble": {
      "title": "需要登录",
      "detail": "未登录",
      "next": "重新登录以继续使用",
      "action": "login",
      "label": "重新登录",
    },
    "makers": {},
    "names": {},
    "series": [],
    "modelsText": "尚未列出模型",
    "available": [],
    "added": [],
    "modelsReading": false,
    "uses": [],
    "providerName": "Google Colab",
    "providerMark": "colab",
    "canAddModel": false,
    "decisionOnly": false,
    "decisionModels": [],
    "share": null,
    "shareable": false,
    "workspaces": [],
    "kindText": "Google Colab",
    "planText": "",
    "signInProvider": "Google Colab",
    "checkLine": "未登录",
  }
  let t2 = setting_tester(Profile("ws1/st1", "colab-exp"), 1280.0, over=fn(s) {
    fn inject(v : Json) -> Json {
      match v {
        Object(o) => {
          let copy = o.copy()
          for k, val in o {
            copy[k] = if k == "profiles" && val is Array(arr) {
              Json::array(arr + [expired])
            } else {
              inject(val)
            }
          }
          Json::object(copy)
        }
        Array(a) => Json::array(a.map(inject))
        _ => v
      }
    }
    {
      ..s,
      topic_read: fn(name, params) {
        let r = s.topic(name, params).get().snapshot()
        { ..r, value: r.value.map(inject) }
      },
    }
  })
  assert_true(t2.find("登录") is Some(_), msg="expired colab profile must show sign-in card")
  assert_eq(t2.audit(), [])
}

///|
test "profiles list shows Google Colab as its own group apart from Google and add profile flow picks colab method under Google" {
  let agy_item : Json = {
    "key": "agy-lin@example.com",
    "group": "agy",
    "groupTitle": "Google",
    "title": "lin@example.com",
    "usable": true,
    "station": "ws1/st1",
    "stationName": "Willow",
    "state": { "text": "", "tone": "neutral" },
    "profile": {
      "id": "agy-1",
      "name": "lin@example.com",
      "runtime": "agy",
      "access": { "kind": "subscription" },
      "providerMark": "gemini",
      "kindText": "Google 订阅",
      "planText": "Ultra 5x",
      "quota": { "state": "ok", "windows": [] },
    },
  }
  let colab_item : Json = {
    "key": "colab-lin@example.com",
    "group": "colab",
    "groupTitle": "Google Colab",
    "title": "lin@example.com",
    "usable": true,
    "station": "ws1/st1",
    "stationName": "Willow",
    "state": { "text": "", "tone": "neutral" },
    "profile": {
      "id": "colab-1",
      "name": "lin@example.com",
      "runtime": null,
      "service": "colab",
      "access": { "kind": "service", "service": "colab" },
      "providerMark": "colab",
      "kindText": "Google Colab",
      "planText": "",
      "quota": {
        "state": "ok",
        "windows": [],
        "creditsText": "2,500 CU",
        "detail": "1 台运行中 · 10.05 CU/h",
      },
    },
  }
  let t_list = setting_tester(Profiles(""), 1280.0, over=fn(s) {
    fn inject_list(v : Json) -> Json {
      match v {
        Object(o) => {
          let copy = o.copy()
          for k, val in o {
            copy[k] = if k == "items" && val is Array(arr) {
              Json::array(arr + [agy_item, colab_item])
            } else {
              inject_list(val)
            }
          }
          Json::object(copy)
        }
        Array(a) => Json::array(a.map(inject_list))
        _ => v
      }
    }
    {
      ..s,
      topic_read: fn(name, params) {
        let r = s.topic(name, params).get().snapshot()
        if name == "profiles" {
          { ..r, value: r.value.map(inject_list) }
        } else {
          r
        }
      },
    }
  })
  assert_true(t_list.find("Google") is Some(_), msg="profiles list shows Google group")
  assert_true(t_list.find("Ultra 5x") is Some(_), msg="profiles list shows Antigravity CLI row")
  assert_true(t_list.find("Google Colab") is Some(_), msg="profiles list shows Google Colab tag on Colab row")
  // (its own section's heading and its row's tag: grouped under Google, only the tag would say it)
  assert_true(
    t_list.words().filter(fn(w) { w.0 == "Google Colab" }).length() >= 2,
    msg="profiles list heads Google Colab's own section",
  )
  assert_true(t_list.find("2,500 CU") is Some(_), msg="profiles list shows CU balance")
  assert_true(t_list.find("1 台运行中 · 10.05 CU/h") is Some(_), msg="profiles list shows active VM detail")
  assert_eq(t_list.audit(), [])

  // Add profile flow: Google method step shows Google Colab option and sends profile.flow.edit(method: "colab")
  let edit_calls : Array[Json] = []
  let method_view : Json = {
    "step": "method",
    "title": "连接 Google",
    "tile": {
      "id": "google",
      "name": "Google",
      "kind": "api-provider",
      "runtime": "agy",
      "service": "colab",
      "mark": "gemini",
      "hasPlan": true,
      "hasKey": true,
    },
    "groups": [],
    "choices": [
      { "id": "plan", "title": "订阅 · Google AI", "hint": "Antigravity CLI" },
      { "id": "enterprise", "title": "企业版 · Gemini Enterprise", "hint": "Gemini Enterprise" },
      { "id": "colab", "title": "Google Colab", "hint": "Google Colab / AI Ultra 账号，用于 GPU 算力任务" },
      { "id": "key", "title": "API key", "hint": "使用 Google Gemini 的 API key，按量计费" },
    ],
    "signIn": null,
    "showKey": false,
    "showEndpoint": false,
    "protocols": [],
    "regions": [],
    "canSubmit": false,
    "pending": false,
    "error": null,
  }
  let t_method = setting_tester(NewProfile("ws1/st1"), 1280.0, over=fn(s) {
    {
      ..s,
      topic_read: fn(name, params) {
        if name == "profileFlow" {
          { value: Some(method_view), version: 1, error: None }
        } else {
          s.topic(name, params).get().snapshot()
        }
      },
      call: fn(name, params, done) {
        if name == "profile.flow.edit" {
          edit_calls.push(params)
          done(Ok(obj([])))
        } else {
          (s.call)(name, params, done)
        }
      },
    }
  })
  assert_true(t_method.find("Google Colab") is Some(_), msg="Google method step shows Google Colab choice")
  assert_eq(t_method.audit(), [])
  t_method.tap_text("Google Colab")
  t_method.frame()
  assert_eq(edit_calls.length(), 1, msg="tapping Google Colab calls profile.flow.edit")
  assert_eq(text(field(Some(edit_calls[0]), "input"), "method"), "colab")

  // Connect step for Google Colab (method=colab) starts login.new with service=colab (no runtime)
  let login_calls : Array[Json] = []
  let connect_view : Json = {
    "step": "connect",
    "method": "colab",
    "title": "连接 Google Colab",
    "groups": [],
    "choices": [],
    "signIn": { "service": "colab", "provider": "Google Colab" },
    "usesLine": "添加后可用于 Google Colab GPU 算力任务",
    "showKey": false,
    "showEndpoint": false,
    "protocols": [],
    "regions": [],
    "canSubmit": false,
    "pending": false,
    "error": null,
  }
  let t_conn = setting_tester(NewProfile("ws1/st1"), 1280.0, over=fn(s) {
    {
      ..s,
      topic_read: fn(name, params) {
        if name == "profileFlow" {
          { value: Some(connect_view), version: 1, error: None }
        } else {
          s.topic(name, params).get().snapshot()
        }
      },
      call: fn(name, params, done) {
        if name == "login.new" {
          login_calls.push(params)
          done(Ok({ "id": "job-colab-1" }))
        } else {
          (s.call)(name, params, done)
        }
      },
    }
  })
  assert_true(t_conn.find("Google Colab GPU 算力任务") is Some(_), msg="connect step shows usesLine")
  assert_eq(login_calls.length(), 1, msg="connect step starts login.new")
  assert_eq(text(Some(login_calls[0]), "service"), "colab", msg="login.new passes service=colab")
  assert_eq(field(Some(login_calls[0]), "runtime"), None, msg="login.new omits runtime for service")
  assert_eq(t_conn.audit(), [])
}

///|
test "a key's profile with no allowance shown, wide: the connect using it sits in the middle of its card" {
  // (k2 shows no allowance; one connect uses it here)
  let t = setting_tester(Profile("ws1/st1", "k2"), 1280.0, over=fn(s) {
    fn inject(v : Json) -> Json {
      match v {
        Object(o) => {
          let copy = o.copy()
          for k, val in o {
            copy[k] = inject(val)
          }
          if o.get("id") == Some(Json::string("k2")) && o.contains("usedBy") {
            copy["usedBy"] = ["k1"]
          }
          Json::object(copy)
        }
        Array(a) => Json::array(a.map(inject))
        _ => v
      }
    }
    {
      ..s,
      topic_read: fn(name, params) {
        let r = s.topic(name, params).get().snapshot()
        { ..r, value: r.value.map(inject) }
      },
    }
  })
  scrolled_to(t, 1280.0, "星火助手")
  guard t.find("星火助手") is Some((x, y)) else { fail("no connect row: \{Repr(t.words().map(fn(w) { w.0 }))}") }
  // (the card it is on: the least drawn ground round its name as tall as a row and its padding at least)
  let card = t
    .drawn_rects()
    .filter(fn(r) { r.0 <= x && x <= r.0 + r.2 && r.1 <= y && y <= r.1 + r.3 && r.3 >= 40.0 && r.3 < 120.0 })
    .fold(init=None, fn(a : (Double, Double, Double, Double, Int64)?, r) {
      match a {
        Some(b) if b.2 * b.3 <= r.2 * r.3 => a
        _ => Some(r)
      }
    })
  guard card is Some(c) else { fail("no card round 星火助手") }
  let off = y - (c.1 + c.3 / 2.0)
  assert_true(off.abs() < 0.5, msg="its name \{off} off its card's middle: \{Repr(c)}, at \{y}")
  assert_eq(t.audit(), [])
}

///|
/// The fixture with each of its overviews' sharing said by a station from before `shareAllowAuto` (`auto_ok` false), or
/// its Claude subscription's share following the workspace's whitelist (`follows`).
fn with_share_auto(s : Source, auto_ok? : Bool = true, follows? : Bool = false) -> Source {
  fn shaped(v : Json, auto_ok : Bool, follows : Bool) -> Json {
    match v {
      Object(o) => {
        let p = o.copy()
        for k, x in o {
          p[k] = shaped(x, auto_ok, follows)
        }
        if !auto_ok {
          p.remove("shareAllowAuto")
        }
        if follows && o.get("id") == Some(Json::string("cc")) && o.get("share") is Some(Object(sh)) {
          let share = sh.copy()
          share["allowAuto"] = Json::boolean(true)
          share["allow"] = Json::array([Json::string("st1"), Json::string("st2")])
          p["share"] = Json::object(share)
        }
        Json::object(p)
      }
      Array(a) => Json::array(a.map(fn(x) { shaped(x, auto_ok, follows) }))
      _ => v
    }
  }
  {
    ..s,
    topic_read: fn(name, params) {
      let v = s.topic(name, params).get().snapshot()
      match v.value {
        Some(x) => { ..v, value: Some(shaped(x, auto_ok, follows)) }
        None => v
      }
    },
  }
}

///|
/// Three stations of the workspace, Maple alone on its whitelist (it takes automatically assigned chats).
let whitelisted_three : Array[Json] = [
  { "id": "st1", "name": "Willow", "online": true, "acceptAutoChats": false },
  { "id": "st2", "name": "Maple", "online": true, "acceptAutoChats": true },
  { "id": "st3", "name": "Birch", "online": true, "acceptAutoChats": false },
]

///|
test "可用的 station follows the workspace's whitelist: the rows show those on it, one ticked by hand chooses by hand" {
  for case in page_cases {
    let (w, platform) = case
    let asked : Array[Json] = []
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, h=2400.0, over=fn(base) {
      let s = with_share_stations(with_share_auto(base), whitelisted_three)
      { ..s, call: fn(name, params, done) {
        if name == "profile.share" {
          asked.push(params)
          done(Ok(obj([])))
        } else {
          (s.call)(name, params, done)
        }
      } }
    })
    let at = "\{w} platform \{platform}"
    scrolled_to(t, w, "可用的 station")
    t.tap_text("可用的 station")
    presented_in(t)
    assert_eq(t.get(Switch, label="全部 station").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="跟随工作区白名单").check, Some(Off), msg=at)
    assert_false(t.get(Switch, label="跟随工作区白名单").disabled, msg=at)
    assert_true(t.find("白名单内现有 1 台 station，随白名单同步") is Some(_), msg=at)
    // On: every station off, the rows those on the whitelist (and this one, always)
    t.click(Switch, label="跟随工作区白名单")
    t.run_for(@ui.move_most_ms)
    assert_eq(t.get(Switch, label="跟随工作区白名单").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="全部 station").check, Some(Off), msg=at)
    assert_eq(t.get(Switch, label="Willow").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="Maple").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="Birch").check, Some(Off), msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    t.click(Button, label="完成")
    t.run_for(@motion.presence_out_ms)
    assert_eq(asked.length(), 1, msg=at)
    assert_eq(field(Some(asked[0]), "allowAuto"), Some(Json::boolean(true)), msg=at)
    assert_eq(field(Some(asked[0]), "allow"), None, msg="\{at}: a rule, no list")
    assert_eq(field(Some(asked[0]), "among"), None, msg=at)
    // Following it, then Maple ticked off by hand: chosen by hand, the rest as it was
    t.tap_text("可用的 station")
    presented_in(t)
    t.click(Switch, label="跟随工作区白名单")
    t.frame()
    t.click(Switch, label="Maple")
    t.run_for(@ui.move_most_ms)
    assert_eq(t.get(Switch, label="跟随工作区白名单").check, Some(Off), msg=at)
    assert_eq(t.get(Switch, label="Maple").check, Some(Off), msg=at)
    t.click(Button, label="完成")
    t.run_for(@motion.presence_out_ms)
    assert_eq(asked.length(), 2, msg=at)
    assert_eq(field(Some(asked[1]), "allowAuto"), None, msg=at)
    assert_eq(field(Some(asked[1]), "allow"), Some(Json::array([Json::string("st1")])), msg=at)
  }
}

///|
test "a share following the whitelist says so on its page and opens following it; a station from before offers it not, saying why" {
  for case in page_cases {
    let (w, platform) = case
    let at = "\{w} platform \{platform}"
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, h=2400.0, over=fn(base) {
      with_share_stations(with_share_auto(base, follows=true), whitelisted_three)
    })
    scrolled_to(t, w, "可用的 station")
    assert_true(t.find("跟随工作区白名单") is Some(_), msg="\{at}: its row's value")
    t.tap_text("可用的 station")
    presented_in(t)
    assert_eq(t.get(Switch, label="跟随工作区白名单").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="Maple").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="Birch").check, Some(Off), msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    let old = setting_tester(Profile("ws1/st1", "cc"), w, platform~, h=2400.0, over=fn(base) {
      with_share_stations(with_share_auto(base, auto_ok=false), whitelisted_three)
    })
    scrolled_to(old, w, "可用的 station")
    old.tap_text("可用的 station")
    presented_in(old)
    assert_true(old.get(Switch, label="跟随工作区白名单").disabled, msg=at)
    assert_true(old.find("该 station 版本较旧，更新后可用") is Some(_), msg=at)
  }
}

///|
test "批量管理 shares several accounts, sets stations at once, stops sharing via more menu, edits single row without ticking, and clears hidden picks on filter switch" {
  for case in page_cases {
    let (w, platform) = case
    let at = "\{w} platform \{platform}"
    let asked : Array[(String, Json)] = []
    let t = setting_tester(ProfilesManage(""), w, platform~, h=1400.0, over=fn(base) {
      let s = with_titled(with_share_auto(base), "cc", "lin@claude.example")
      { ..s, call: fn(name, params, done) {
        if name == "profile.share" || name == "profile.move" || name == "profile.check" || name == "profile.quota" || name == "profile.delete" {
          asked.push((name, params))
          done(Ok(obj([])))
        } else {
          (s.call)(name, params, done)
        }
      } }
    })
    t.run_for(@ui.move_most_ms)
    // Initially nothing selected: floating batch bar is hidden.
    assert_true(t.find("已选 ") is None, msg="\{at}: bar hidden with 0 selected")
    assert_true(t.find("Claude 主账号") is Some(_) && t.find("lin@claude.example") is None, msg="\{at}: a row keeps its name")
    // 1. Clicking right policy button (a11y label includes account name) opens pick_stations without ticking the row;
    //    both 取消 and 停止分享 are present when already shared (H1).
    t.click(Button, label="Claude 主账号 · 所有 station")
    presented_in(t)
    assert_true(t.find("已选 ") is None, msg="\{at}: editing policy must not tick row")
    assert_true(t.query(Button, label="取消") is Some(_), msg="\{at}: pick_stations keeps cancel alongside stop")
    assert_true(t.query(Button, label="停止分享") is Some(_), msg="\{at}: pick_stations offers stop sharing when already shared")
    t.click(Button, label="停止分享")
    presented_in(t)
    assert_true(t.find("停止分享此账号？") is Some(_), msg="\{at}: single stop confirmation")
    t.click(Button, label="取消")
    t.run_for(@motion.presence_out_ms)
    // 2. Ticking checkboxes selects rows without opening pick_stations.
    t.click(Checkbox, label="Claude 主账号")
    t.click(Checkbox, label="备用 key")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("已选 2 项") is Some(_), msg=at)
    assert_false(t.get(Button, label="共享").disabled, msg=at)
    assert_true(t.query(Button, label="迁移") is Some(_), msg=at)
    assert_true(t.query(Button, label="刷新") is Some(_), msg=at)
    assert_true(t.query(Button, label="删除") is Some(_), msg=at)
    assert_true(t.query(Button, label="更多操作") is Some(_), msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    // 3. Switching sharing filter to 未分享 prunes hidden shared selection (Claude 主账号) while keeping visible unshared (备用 key).
    t.click(Button, label="全部共享")
    presented_in(t)
    t.click(MenuItemCheckbox, label="未分享")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("已选 1 项") is Some(_), msg="\{at}: switching filter clears hidden selections")
    t.click(Button, label="未分享")
    presented_in(t)
    t.click(MenuItemCheckbox, label="手动")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("Claude 主账号") is Some(_), msg="\{at}: 手动 filter includes all-stations shared row")
    assert_true(t.find("已选 ") is None, msg="\{at}: switching to 手动 prunes 备用 key")
    t.click(Button, label="手动")
    presented_in(t)
    t.click(MenuItemCheckbox, label="全部共享")
    t.run_for(@ui.move_most_ms)
    t.click(Checkbox, label="Claude 主账号")
    t.click(Checkbox, label="备用 key")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("已选 2 项") is Some(_), msg=at)
    // 4. Batch apply mixed policies opens neutral undecided state (H2): Primary disabled until user explicitly chooses.
    t.click(Button, label="共享")
    presented_in(t)
    assert_true(t.find("将应用于 2 个 Profile") is Some(_), msg=at)
    assert_true(t.find("保存后将把所选账号统一更新为下方策略") is Some(_), msg=at)
    assert_eq(t.get(Switch, label="跟随工作区白名单").check, Some(Off), msg="\{at}: mixed selection starts neutral undecided")
    assert_true(t.get(Button, label="完成").disabled, msg="\{at}: neutral undecided disables primary until user chooses")
    t.click(Switch, label="跟随工作区白名单")
    t.run_for(@ui.move_most_ms)
    assert_false(t.get(Button, label="完成").disabled, msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    t.click(Button, label="完成")
    t.run_for(@motion.presence_out_ms)
    assert_eq(asked.length(), 2, msg=at)
    for a in asked {
      assert_eq(a.0, "profile.share", msg=at)
      assert_eq(text(Some(a.1), "station"), "ws1/st1", msg=at)
      assert_eq(field(Some(a.1), "allowAuto"), Some(Json::boolean(true)), msg=at)
    }
    // Wide batch dock is a flow child (`ComeGroup` collapse animation); wait for collapse before checking DOM removal.
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("已选 ") is None, msg="\{at}: selection cleared after batch update")
    // 5. Batch stop sharing via ⋯ more menu asks confirmation and only stops shared rows.
    t.click(Checkbox, label="Claude 主账号")
    t.click(Checkbox, label="备用 key")
    t.run_for(@ui.move_most_ms)
    t.click(Button, label="更多操作")
    presented_in(t)
    let menu_role : @ui.Role = if t.query(MenuItem, label="停止分享") is Some(_) { MenuItem } else { Button }
    t.click(menu_role, label="停止分享")
    presented_in(t)
    assert_eq(asked.length(), 2, msg="\{at}: asked first")
    assert_true(t.find("停止分享 1 个账号？") is Some(_), msg="\{at}: the key not shared is left as it is")
    let stops = t.all(Button, label="停止分享")
    let (x, y, bw, bh) = stops[stops.length() - 1].rect
    t.tap(x + bw / 2.0, y + bh / 2.0)
    t.run_for(@motion.presence_out_ms)
    assert_eq(asked.length(), 3, msg=at)
    assert_eq(field(Some(asked[2].1), "on"), Some(Json::boolean(false)), msg=at)
    assert_eq(text(Some(asked[2].1), "id"), "cc", msg=at)
    // 6. Direct batch refresh button calls profile.check (+ profile.quota only when supported).
    t.click(Checkbox, label="Claude 主账号")
    t.click(Checkbox, label="备用 key")
    t.run_for(@ui.move_most_ms)
    t.click(Button, label="刷新")
    t.run_for(@motion.presence_out_ms)
    assert_true(asked.iter().any(fn(a) { a.0 == "profile.check" && text(Some(a.1), "id") == "cc" }), msg=at)
    assert_true(asked.iter().any(fn(a) { a.0 == "profile.quota" && text(Some(a.1), "id") == "cc" }), msg=at)
    assert_true(asked.iter().any(fn(a) { a.0 == "profile.check" && text(Some(a.1), "id") == "k2" }), msg=at)
    assert_false(asked.iter().any(fn(a) { a.0 == "profile.quota" && text(Some(a.1), "id") == "k2" }), msg="\{at}: must not send profile.quota when quota.state == unsupported")
    // 7. Direct batch delete button shows danger confirmation with account & host names and calls profile.delete.
    t.click(Checkbox, label="备用 key")
    t.run_for(@ui.move_most_ms)
    t.click(Button, label="删除")
    presented_in(t)
    assert_true(t.find("删除 1 个账号？") is Some(_), msg=at)
    assert_true(t.find("备用 key (Willow)") is Some(_), msg=at)
    let dels = t.all(Button, label="删除")
    let (dx, dy, dw, dh) = dels[dels.length() - 1].rect
    t.tap(dx + dw / 2.0, dy + dh / 2.0)
    t.run_for(@motion.presence_out_ms)
    assert_true(asked.iter().any(fn(a) { a.0 == "profile.delete" && text(Some(a.1), "id") == "k2" }), msg=at)
  }
}

///|
test "批量管理 station filter, batch move with machine skip and partial failure retention" {
  let moves : Array[Json] = []
  let t = setting_tester(ProfilesManage(""), 900.0, platform=0, h=800.0, over=fn(base) {
    let s = with_share_auto(base)
    {
      ..s,
      topic_read: fn(name, params) {
        let v = s.topic(name, params).get().snapshot()
        if name == "stations" {
          match v.value {
            Some(Array(arr)) => {
              let out = arr.map(fn(st) {
                match st {
                  Object(so) => {
                    let sm = so.copy()
                    sm["online"] = Json::boolean(true)
                    Json::object(sm)
                  }
                  _ => st
                }
              })
              { ..v, value: Some(Json::array(out)) }
            }
            _ => v
          }
        } else if name == "profiles" {
          match v.value {
            Some(Object(o)) => {
              let m = o.copy()
              let its = items(v.value, "items").map(fn(r) {
                if text(field(Some(r), "profile"), "id") == "k2" {
                  match r {
                    Object(ro) => {
                      let rm = ro.copy()
                      rm["machine"] = Json::boolean(true)
                      Json::object(rm)
                    }
                    _ => r
                  }
                } else {
                  r
                }
              })
              m["items"] = Json::array(its)
              { ..v, value: Some(Json::object(m)) }
            }
            _ => v
          }
        } else {
          v
        }
      },
      call: fn(name, params, done) {
        if name == "profile.move" {
          moves.push(params)
          if text(Some(params), "id") == "cc" {
            done(Err(Json::object({ "message": Json::string("disk full") })))
          } else {
            done(Ok(obj([])))
          }
        } else {
          (s.call)(name, params, done)
        }
      },
    }
  })
  t.run_for(@ui.move_most_ms)
  // Station dropdown filters by host station.
  t.click(Button, label="全部 station")
  presented_in(t)
  t.click(MenuItemCheckbox, label="Maple")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("当前筛选下没有账号") is Some(_), msg="Maple has no profiles in fixture")
  t.click(Button, label="Maple")
  presented_in(t)
  t.click(MenuItemCheckbox, label="全部 station")
  t.run_for(@ui.move_most_ms)
  // Select 2 movable (cc, cx) + 1 machine (ak): move dialog skips machine and moves remaining to Maple.
  t.click(Checkbox, label="Claude 主账号")
  t.click(Checkbox, label="备用 key")
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="迁移")
  presented_in(t)
  assert_true(t.find("无法迁移") is Some(_) && t.find("自动跳过") is Some(_), msg="machine login skip note shown")
  assert_true(t.find("当前所在") is Some(_), msg="Willow marked as current station")
  t.click(Link, label="Maple")
  presented_in(t)
  assert_true(t.find("迁移 1 个账号到 Maple？") is Some(_), msg="move confirm counts movable rows")
  t.click(Button, label="迁移")
  t.run_for(@motion.presence_out_ms)
  assert_eq(moves.length(), 1)
  assert_eq(text(Some(moves[0]), "id"), "cc")
  assert_eq(text(Some(moves[0]), "to"), "st2")
  // Failed move retains failed selection for retry.
  assert_true(t.find("已选 1 项") is Some(_), msg="failed row stays selected for retry")
}

///|
test "批量管理 R2 regressions: SWR version -2 skipped, single-station empty profileGroups, unsupported+offline unselectable, and batch delete skips machine" {
  // 1. SWR cache (version == -2) with allow: null must NOT open pick_stations; fresh version == 1 opens with custom allow.
  let ver : @signals.Signal[Int] = @signals.signal(-2)
  let t1 = setting_tester(ProfilesManage(""), 900.0, platform=0, h=1400.0, over=fn(base) {
    let s = with_share_auto(base)
    {
      ..s,
      topic_read: fn(name, params) {
        let v = s.topic(name, params).get().snapshot()
        if name == "station" {
          let cur_ver = ver.get()
          match v.value {
            Some(Object(o)) => {
              let m = o.copy()
              match field(v.value, "overview") {
                Some(Object(ov)) => {
                  let ovm = ov.copy()
                  let ps = items(Some(Json::object(ov)), "profiles").map(fn(p) {
                    if text(Some(p), "id") == "cc" {
                      match p {
                        Object(po) => {
                          let pm = po.copy()
                          pm["share"] = if cur_ver < 0 {
                            obj([("id", str("sh-1")), ("role", str("host")), ("host", str("st1"))])
                          } else {
                            obj([
                              ("id", str("sh-1")),
                              ("role", str("host")),
                              ("host", str("st1")),
                              ("allow", Json::array([str("st1")])),
                            ])
                          }
                          Json::object(pm)
                        }
                        _ => p
                      }
                    } else {
                      p
                    }
                  })
                  ovm["profiles"] = Json::array(ps)
                  m["overview"] = Json::object(ovm)
                }
                _ => ()
              }
              { ..v, value: Some(Json::object(m)), version: cur_ver }
            }
            _ => { ..v, version: cur_ver }
          }
        } else {
          v
        }
      },
    }
  })
  t1.run_for(@ui.move_most_ms)
  t1.click(Button, label="Claude 主账号 · 所有 station")
  t1.run_for(@sf.open_hold_ms + 100.0)
  assert_false(@sf.presenting(), msg="B1 SWR: version -2 cache must not open pick_stations")
  ver.set(1)
  t1.run_for(@ui.move_most_ms)
  presented_in(t1)
  assert_eq(t1.get(Switch, label="全部 station").check, Some(Off), msg="B1 SWR: fresh version 1 preserves custom allow")
  t1.click(Button, label="取消")
  t1.run_for(@motion.presence_out_ms)

  // 2. Single-station profileGroups: [] with non-empty overview.profiles renders empty state (0 rows).
  let t2 = setting_tester(ProfilesManage("ws1/st1"), 900.0, platform=0, h=800.0, over=fn(base) {
    {
      ..base,
      topic_read: fn(name, params) {
        let v = base.topic(name, params).get().snapshot()
        if name == "station" {
          match v.value {
            Some(Object(o)) => {
              let m = o.copy()
              m["profileGroups"] = Json::array([])
              { ..v, value: Some(Json::object(m)) }
            }
            _ => v
          }
        } else {
          v
        }
      },
    }
  })
  t2.run_for(@ui.move_most_ms)
  assert_true(t2.query(Checkbox, label="Claude 主账号") is None, msg="H1: empty profileGroups must not fall back to overview.profiles")
  assert_true(t2.find("暂无可管理的账号") is Some(_), msg="H1: empty profileGroups shows empty state")

  // 3. unsupported + offline cannot be selected, and going offline clears selection.
  let st1_online : @signals.Signal[Bool] = @signals.signal(true)
  let t3 = setting_tester(ProfilesManage(""), 900.0, platform=0, h=1400.0, over=fn(base) {
    let s = with_share_auto(base)
    {
      ..s,
      topic_read: fn(name, params) {
        let v = s.topic(name, params).get().snapshot()
        let on = st1_online.get()
        if name == "stations" {
          match v.value {
            Some(Array(arr)) => {
              let out = arr.map(fn(st) {
                if text(Some(st), "station") == "ws1/st1" {
                  match st {
                    Object(so) => {
                      let sm = so.copy()
                      sm["online"] = Json::boolean(on)
                      Json::object(sm)
                    }
                    _ => st
                  }
                } else {
                  st
                }
              })
              { ..v, value: Some(Json::array(out)) }
            }
            _ => v
          }
        } else if name == "profiles" {
          match v.value {
            Some(Object(o)) => {
              let m = o.copy()
              let its = items(v.value, "items").map(fn(r) {
                match r {
                  Object(ro) => {
                    let rm = ro.copy()
                    rm["canBatchShare"] = Json::boolean(false)
                    rm["batchShareWhy"] = str("unsupported")
                    Json::object(rm)
                  }
                  _ => r
                }
              })
              m["items"] = Json::array(its)
              { ..v, value: Some(Json::object(m)) }
            }
            _ => v
          }
        } else {
          v
        }
      },
    }
  })
  t3.run_for(@ui.move_most_ms)
  t3.click(Checkbox, label="Claude 主账号")
  t3.run_for(@ui.move_most_ms)
  assert_true(t3.find("已选 1 项") is Some(_), msg="H3: online unsupported row is selectable")
  st1_online.set(false)
  t3.run_for(@ui.move_most_ms)
  assert_true(t3.find("已选 ") is None, msg="H3: going offline clears selection on unsupported row")
  assert_true(t3.get(Checkbox, label="Claude 主账号").disabled, msg="H3: offline unsupported row checkbox is disabled")

  // 4. Batch delete skips machine login and disables delete when only machine login is selected.
  let deleted : Array[String] = []
  let t4 = setting_tester(ProfilesManage(""), 900.0, platform=0, h=1400.0, over=fn(base) {
    let s = with_share_auto(base)
    {
      ..s,
      topic_read: fn(name, params) {
        let v = s.topic(name, params).get().snapshot()
        if name == "profiles" {
          match v.value {
            Some(Object(o)) => {
              let m = o.copy()
              let its = items(v.value, "items").map(fn(r) {
                if text(field(Some(r), "profile"), "id") == "k2" {
                  match r {
                    Object(ro) => {
                      let rm = ro.copy()
                      rm["machine"] = Json::boolean(true)
                      Json::object(rm)
                    }
                    _ => r
                  }
                } else {
                  r
                }
              })
              m["items"] = Json::array(its)
              { ..v, value: Some(Json::object(m)) }
            }
            _ => v
          }
        } else {
          v
        }
      },
      call: fn(name, params, done) {
        if name == "profile.delete" {
          deleted.push(text(Some(params), "id"))
          done(Ok(obj([])))
        } else {
          (s.call)(name, params, done)
        }
      },
    }
  })
  t4.run_for(@ui.move_most_ms)
  t4.click(Checkbox, label="备用 key")
  t4.run_for(@ui.move_most_ms)
  assert_true(t4.get(Button, label="删除").disabled, msg="M1+M6: delete disabled when only machine login selected")
  t4.click(Checkbox, label="Claude 主账号")
  t4.run_for(@ui.move_most_ms)
  t4.click(Button, label="删除")
  presented_in(t4)
  assert_true(t4.find("删除 1 个账号？") is Some(_), msg="M1+M6: confirm title counts only deletable rows")
  assert_true(t4.find("跳过 1 个本机登录") is Some(_), msg="M1+M6: confirm body states skipped machine login")
  let dels = t4.all(Button, label="删除")
  let (dx, dy, dw, dh) = dels[dels.length() - 1].rect
  t4.tap(dx + dw / 2.0, dy + dh / 2.0)
  t4.run_for(@motion.presence_out_ms)
  assert_eq(deleted, ["cc"], msg="M1+M6: only non-machine row deleted")
}

///|
test "批量管理 B1 single-row authoritative read preserves allow, rejects error/missing without fallback, and H2 single custom row reuses it" {
  let station_ready : @signals.Signal[Bool] = @signals.signal(false)
  let station_err : @signals.Signal[Bool] = @signals.signal(false)
  let t = setting_tester(ProfilesManage(""), 900.0, platform=0, h=800.0, over=fn(base) {
    let s = with_share_auto(base)
    {
      ..s,
      topic_read: fn(name, params) {
        let v = s.topic(name, params).get().snapshot()
        if name == "station" {
          if !station_ready.get() {
            { ..v, value: None, error: None }
          } else if station_err.get() {
            { ..v, value: None, error: Some(Json::object({ "message": Json::string("unreachable") })) }
          } else {
            match v.value {
              Some(Object(o)) => {
                let m = o.copy()
                match field(v.value, "overview") {
                  Some(Object(ov)) => {
                    let ovm = ov.copy()
                    let ps = items(Some(Json::object(ov)), "profiles").map(fn(p) {
                      if text(Some(p), "id") == "cc" {
                        match p {
                          Object(po) => {
                            let pm = po.copy()
                            pm["share"] = obj([
                              ("id", str("sh-1")),
                              ("role", str("host")),
                              ("host", str("st1")),
                              ("allow", Json::array([str("st1")])),
                            ])
                            Json::object(pm)
                          }
                          _ => p
                        }
                      } else {
                        p
                      }
                    })
                    ovm["profiles"] = Json::array(ps)
                    m["overview"] = Json::object(ovm)
                  }
                  _ => ()
                }
                { ..v, value: Some(Json::object(m)) }
              }
              _ => v
            }
          }
        } else {
          v
        }
      },
    }
  })
  t.run_for(@ui.move_most_ms)
  // Click single row while station topic is pending: does NOT fall back after open_hold_ms.
  t.click(Button, label="Claude 主账号 · 所有 station")
  t.run_for(@sf.open_hold_ms + 100.0)
  assert_false(@sf.presenting(), msg="B1: must not fall back to lightweight row on slow station read")
  // When error arrives: shows toast and never opens dialog.
  station_err.set(true)
  station_ready.set(true)
  t.run_for(@ui.move_most_ms)
  assert_false(@sf.presenting(), msg="B1: error must not open station picker")
  // Now answer cleanly with custom allow=[st1, st2] and test H2 (ticking 1 row + pressing 设置共享).
  station_err.set(false)
  t.click(Checkbox, label="Claude 主账号")
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="共享")
  presented_in(t)
  // Custom allow list [st1] must be preserved (Maple Off, All stations Off).
  assert_eq(t.get(Switch, label="全部 station").check, Some(Off), msg="H2+B1: custom allow preserved, not broadened to all")
  assert_eq(t.get(Switch, label="Maple").check, Some(Off), msg="H2+B1: Maple stays excluded by custom allow")
  t.click(Button, label="取消")
  t.run_for(@motion.presence_out_ms)
}

///|
test "H1 account detail pick_stations keeps cancel and never shows duplicate stop sharing" {
  let t = setting_tester(Profile("ws1/st1", "cc"), 900.0, platform=0, h=1400.0, over=fn(base) { with_share_auto(base) })
  t.run_for(@ui.move_most_ms)
  t.click(Link, label="可用的 station")
  presented_in(t)
  assert_true(t.query(Button, label="取消") is Some(_), msg="H1: detail pick_stations keeps cancel")
  assert_true(t.query(Button, label="停止分享") is None, msg="H1: detail pick_stations must not duplicate stop sharing")
  t.click(Button, label="取消")
  t.run_for(@motion.presence_out_ms)
}

///|
/// The fixture's `profiles` rows with the account of profile `id` titled `title` (an account's email, not its profile's
/// name), and that row made one sharing management cannot edit directly on the workspace's list (`several`).
fn with_titled(s : Source, id : String, title : String, several? : Bool = false) -> Source {
  fn shaped(v : Json, id : String, title : String, several : Bool) -> Json {
    match v {
      Object(o) => {
        let p = o.copy()
        for k, x in o {
          p[k] = shaped(x, id, title, several)
        }
        if o.contains("canBatchShare") && text(field(Some(v), "profile"), "id") == id {
          p["title"] = Json::string(title)
          if several {
            p["canBatchShare"] = Json::boolean(false)
            p["batchShareWhy"] = Json::string("several")
          }
        }
        Json::object(p)
      }
      Array(a) => Json::array(a.map(fn(x) { shaped(x, id, title, several) }))
      _ => v
    }
  }
  {
    ..s,
    topic_read: fn(name, params) {
      let v = s.topic(name, params).get().snapshot()
      match v.value {
        Some(x) if name == "profiles" => { ..v, value: Some(shaped(x, id, title, several)) }
        _ => v
      }
    },
  }
}

///|
test "single-station 批量管理 filters via profileGroups, handles deleted/offline/demotion, and role demotion auto-pops" {
  for case in page_cases {
    let (w, platform) = case
    let at = "\{w} platform \{platform}"
    let one = setting_tester(ProfilesManage("ws1/st1"), w, platform~, h=1400.0, over=fn(base) {
      with_titled(with_share_auto(base), "cc", "Claude 主账号", several=true)
    })
    one.run_for(@ui.move_most_ms)
    one.click(Checkbox, label="Claude 主账号")
    one.run_for(@ui.move_most_ms)
    assert_true(one.find("已选 1 项") is Some(_), msg="\{at}: this station's own, taken here")
    assert_true(one.find("多台 station 独立登录，请点进分别设置") is None, msg=at)
    assert_eq(one.audit(), [], msg="\{at}: " + one.audit().join("; "))
  }
  // H4: deleted station shows station-gone instead of spinning forever.
  let gone = setting_tester(ProfilesManage("ws1/deleted-st"), 390.0, platform=2, h=844.0, over=fn(base) { with_share_auto(base) })
  gone.run_for(@ui.move_most_ms)
  assert_true(gone.find("该 station 已从工作区移除") is Some(_), msg="H4: deleted station shows clear message")
  // Role demotion: manages flipping to false pops ProfilesManage automatically.
  let manages : @signals.Signal[Bool] = @signals.signal(true)
  let t = setting_tester(ProfilesManage(""), 390.0, platform=2, h=844.0, over=fn(base) {
    {
      ..base,
      topic_read: fn(name, params) {
        let v = base.topic(name, params).get().snapshot()
        if name == "profiles" {
          match v.value {
            Some(Object(o)) => {
              let m = o.copy()
              m["manages"] = Json::boolean(manages.get())
              { ..v, value: Some(Json::object(m)) }
            }
            _ => v
          }
        } else {
          v
        }
      },
    }
  })
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() == Setting(ProfilesManage("")))
  manages.set(false)
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() != Setting(ProfilesManage("")), msg="losing manages pops ProfilesManage")
}

///|
test "批量管理 320px + 1.3x font scale in zh and en has zero truncation and zero audit faults" {
  for lang in ["zh", "en"] {
    let t = setting_tester(ProfilesManage(""), 320.0, platform=2, h=640.0, over=fn(base) { with_share_auto(base) })
    @sf.set_language(Some(lang))
    t.set_font_scale(1.3)
    t.run_for(@ui.move_most_ms)
    assert_eq(t.fixed_outgrown(), [], msg="\{lang} outgrown: " + t.fixed_outgrown().join("; "))
    assert_eq(t.squeeze_faults(), [], msg="\{lang} squeeze: " + t.squeeze_faults().join("; "))
    assert_eq(t.words_over_now(), [], msg="\{lang} words_over: " + t.words_over_now().join("; "))
    assert_eq(t.corner_faults(), [], msg="\{lang} corners: " + t.corner_faults().join("; "))
  }
  @sf.set_language(None)
}

///|
test "profiles_batch_foot_node (page=true): liquid glass card with outside shadow, 1pt solid fallback, 0 corner faults, and last row scrollable clear of bar" {
  for dark in [false, true] {
    for case in [(900.0, 0), (390.0, 2)] {
      let (w, platform) = case
      let at = "dark=\{dark} w=\{w} platform=\{platform}"
      let t = setting_tester(ProfilesManage(""), w, platform~, h=640.0, over=fn(base) { with_share_auto(base) })
      @sf.set_dark(Some(dark))
      @ui.set_glass_solid(None)
      t.draw()
      assert_eq(@sf.theme().dark, dark, msg="\{at}: theme().dark must match")
      t.click(Checkbox, label="Claude 主账号")
      t.run_for(@ui.move_most_ms)
      assert_true(t.find("已选 1 项") is Some(_), msg=at)
      let share_btn = t.get(Button, label="共享")
      let move_btn = t.get(Button, label="迁移")
      // Card sits below the table (wide flow-child) or at the bottom of the viewport (narrow floating dock)
      let min_bottom = if w <= 390.0 { 450.0 } else { 200.0 }
      let bar_glass = t.drawn_glass().filter(fn(g) { g.1 + g.3 > min_bottom && g.2 > 200.0 })
      let bar_liquid = bar_glass.filter(fn(g) { g.4 == 6 })
      let bar_shadow = t
        .drawn_instances()
        .iter()
        .any(fn(a) { a.length() > 12 && a[5] == 2.0 && a[12] == 1.0 && a[1] + a[3] > min_bottom && a[2] > 200.0 })
      assert_eq((at, bar_glass.length(), bar_liquid.length(), bar_shadow), (at, 1, 1, true))
      assert_eq(t.corner_faults(), [], msg="\{at}: corner faults")
      let g = bar_liquid[0]
      assert_true(
        share_btn.rect.0 >= g.0 + 4.0 &&
        share_btn.rect.1 + share_btn.rect.3 <= g.1 + g.3 - 4.0 &&
        move_btn.rect.0 >= g.0 + 4.0 &&
        move_btn.rect.1 + move_btn.rect.3 <= g.1 + g.3 - 4.0,
        msg="\{at}: buttons inside card g=\{Repr(g)} share=\{Repr(share_btn.rect)} move=\{Repr(move_btn.rect)}",
      )
      if w <= 390.0 {
        t.resize(320.0, 640.0)
        t.set_font_scale(1.3)
        t.run_for(@ui.move_most_ms)
        assert_eq(t.corner_faults(), [], msg="\{at}: 320pt 1.3x corner faults")
        for _ in 0..<12 {
          t.wheel(160.0, 200.0, 200.0)
        }
        t.run_for(@ui.move_most_ms)
        let narrow_bar_top = t.drawn_glass().filter(fn(gl) { gl.1 + gl.3 > 400.0 && gl.2 > 200.0 })[0].1
        guard t.query(Checkbox, label="备用 key") is Some(last_cb) else {
          fail("\{at}: narrow wrapped last row (备用 key) not found after scrolling")
        }
        assert_true(
          last_cb.rect.1 + last_cb.rect.3 <= narrow_bar_top,
          msg="\{at}: narrow wrapped last row bottom \{last_cb.rect.1 + last_cb.rect.3} must be <= bar_top \{narrow_bar_top}",
        )
        t.set_font_scale(1.0)
        t.resize(w, 640.0)
        t.run_for(@ui.move_most_ms)
      } else {
        for _ in 0..<12 {
          t.wheel(w / 2.0, 200.0, 200.0)
        }
        t.run_for(@ui.move_most_ms)
        let wide_bar_top = t.drawn_glass().filter(fn(gl) { gl.1 + gl.3 > 200.0 && gl.2 > 200.0 })[0].1
        guard t.query(Checkbox, label="备用 key") is Some(last_cb) else {
          fail("\{at}: wide last row (备用 key) not found after scrolling")
        }
        assert_true(
          last_cb.rect.1 + last_cb.rect.3 <= wide_bar_top,
          msg="\{at}: wide last row bottom \{last_cb.rect.1 + last_cb.rect.3} must be <= bar_top \{wide_bar_top}",
        )
      }
      // MBUI_GLASS=solid fallback: 0 glass + 1pt border
      @ui.set_glass_solid(Some(true))
      t.draw()
      t.run_for(@ui.move_most_ms)
      assert_eq(@sf.theme().dark, dark, msg="\{at}: solid theme().dark must match")
      let solid_glass = t.drawn_glass().filter(fn(gl) { gl.1 + gl.3 > min_bottom && gl.2 > 200.0 })
      let solid_edges = t
        .boxes_held()
        .filter(fn(b) { b.border_w >= 0.9 && b.y + b.h > min_bottom && b.w > 200.0 })
        .map(fn(b) { b.border_w })
      assert_eq((at, solid_glass.length(), solid_edges), (at, 0, [1.0]))
      assert_eq(t.corner_faults(), [], msg="\{at}: solid corner faults")
      @ui.set_glass_solid(None)
    }
  }
  @ui.set_glass_solid(None)
  @sf.set_dark(None)
}

///|
test "批量管理键盘焦点可分别激活左侧勾选框与右侧策略按钮（无障碍标签含账号名）" {
  let t = setting_tester(ProfilesManage(""), 900.0, platform=0, h=800.0, over=fn(base) { with_share_auto(base) })
  // Focus checkbox and activate with Space
  t.act(Checkbox, Focus, label="Claude 主账号")
  t.frame()
  t.key(@ui.key_space)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Checkbox, label="Claude 主账号").check, Some(On), msg="Space toggles checkbox")
  assert_true(t.find("已选 1 项") is Some(_), msg="keyboard selection updates batch bar")
  // Focus sibling policy button (with account name in a11y label) and activate with Enter
  t.act(Button, Focus, label="Claude 主账号 · 所有 station")
  t.frame()
  t.key(@ui.key_code_enter)
  t.run_for(@motion.presence_in_ms)
  assert_true(@sf.presenting(), msg="Enter on policy button opens station picker")
}

///|
test "批量管理 R3 fixes: workspace None blocks confirm RPC, unchecked subscription refreshes quota, missing host unselectable, online null overview waits" {
  // 1. Astra M2: missing host in non-empty stations roster is unselectable.
  let row_missing : Json = obj([
    ("key", str("k-miss")),
    ("station", str("ws1/gone-st")),
    ("batchShareWhy", str("")),
  ])
  let roster : Array[Json] = [obj([("station", str("ws1/st1")), ("online", Json::boolean(true))])]
  assert_false(can_select_row(row_missing, stations=roster), msg="M2: host absent from roster must not be selectable")
  // 2. Astra High: opening confirm then losing active workspace (workspace_in_view -> None) sends zero RPC.
  let ws_gone : @signals.Signal[Bool] = @signals.signal(false)
  let rpcs : Array[(String, String)] = []
  let t = setting_tester(ProfilesManage(""), 900.0, platform=0, h=800.0, over=fn(base) {
    let s = with_share_auto(base)
    {
      ..s,
      topic_read: fn(name, params) {
        let v = s.topic(name, params).get().snapshot()
        if name == "workspaces" && ws_gone.get() {
          { ..v, value: Some(Json::array([])) }
        } else if name == "profiles" {
          // Strip quota from Claude subscription ("cc") to test Opus M1 (unchecked subscription still queries quota).
          match v.value {
            Some(Object(o)) => {
              let m = o.copy()
              let its = items(v.value, "items").map(fn(r) {
                if text(field(Some(r), "profile"), "id") == "cc" {
                  match r {
                    Object(ro) => {
                      let rm = ro.copy()
                      match field(Some(r), "profile") {
                        Some(Object(po)) => {
                          let pm = po.copy()
                          pm.remove("quota")
                          rm["profile"] = Json::object(pm)
                        }
                        _ => ()
                      }
                      Json::object(rm)
                    }
                    _ => r
                  }
                } else {
                  r
                }
              })
              m["items"] = Json::array(its)
              { ..v, value: Some(Json::object(m)) }
            }
            _ => v
          }
        } else {
          v
        }
      },
      call: fn(name, params, done) {
        rpcs.push((name, text(Some(params), "id")))
        done(Ok(obj([])))
      },
    }
  })
  t.run_for(@ui.move_most_ms)
  // Opus M1: unchecked subscription ("cc" without quota object) triggers BOTH profile.check and profile.quota.
  t.click(Checkbox, label="Claude 主账号")
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="刷新")
  t.run_for(@motion.presence_out_ms)
  assert_true(rpcs.contains(("profile.check", "cc")), msg="Opus M1: sends profile.check for unchecked subscription")
  assert_true(rpcs.contains(("profile.quota", "cc")), msg="Opus M1: sends profile.quota for unchecked subscription")
  rpcs.clear()
  // Astra High: open Delete confirm dialog, then active workspace becomes None -> clicking confirm sends zero RPC.
  t.click(Checkbox, label="Claude 主账号")
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="删除")
  presented_in(t)
  ws_gone.set(true)
  t.run_for(@ui.move_most_ms)
  let dels = t.all(Button, label="删除")
  let (dx, dy, dw, dh) = dels[dels.length() - 1].rect
  t.tap(dx + dw / 2.0, dy + dh / 2.0)
  t.run_for(@motion.presence_out_ms)
  assert_eq(rpcs.length(), 0, msg="Astra High: workspace None must block confirm RPC")
  // 3. Astra M3: online station with overview: null stays waiting (does not show empty state).
  let t2 = setting_tester(ProfilesManage("ws1/st1"), 900.0, platform=0, h=800.0, over=fn(base) {
    let s = with_share_auto(base)
    {
      ..s,
      topic_read: fn(name, params) {
        let v = s.topic(name, params).get().snapshot()
        if name == "station" {
          match v.value {
            Some(Object(o)) => {
              let m = o.copy()
              m.remove("overview")
              { ..v, value: Some(Json::object(m)) }
            }
            _ => v
          }
        } else {
          v
        }
      },
    }
  })
  t2.run_for(@ui.move_most_ms)
  assert_true(t2.find("暂无可管理共享的账号") is None, msg="Astra M3: online station with null overview must wait, not show empty")
}

///|
test "profiles_manage table: master checkbox, filter-empty, conditional whitelist hint, and 320pt 1.3x en dock clearance" {
  // 1. Wide workspace table: master select-all checkbox selects all selectable rows and flips label, then clears.
  let empty_wl = fn(base : Source) {
    let s = with_share_auto(base)
    {
      ..s,
      topic_read: fn(name, params) {
        let v = s.topic(name, params).get().snapshot()
        if name == "stations" {
          match v.value {
            Some(Array(sts)) => {
              let out = sts.map(fn(st) {
                match st {
                  Object(o) => {
                    let m = o.copy()
                    m["acceptAutoChats"] = Json::boolean(false)
                    Json::object(m)
                  }
                  _ => st
                }
              })
              { ..v, value: Some(Json::array(out)) }
            }
            _ => v
          }
        } else {
          v
        }
      },
    }
  }
  let t = setting_tester(ProfilesManage(""), 900.0, platform=0, h=800.0, over=empty_wl)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("账号") is Some(_), msg="table header shows 账号 column")
  assert_true(t.find("Station") is Some(_), msg="wide table header shows Station column")
  assert_true(t.find("状态") is Some(_), msg="wide table header shows 状态 column")
  assert_true(t.find("共享") is Some(_), msg="table header shows 共享 column")
  assert_true(t.find("白名单暂无 station") is None, msg="whitelist-empty hint hidden by default when no whitelist accounts exist")
  let tbl_h_before = t.get(Table).rect.3
  t.click(Checkbox, label="全选")
  t.run_for(@ui.move_most_ms)
  let tbl_h_selected = t.get(Table).rect.3
  assert_true(
    (tbl_h_before - tbl_h_selected).abs() < 0.5,
    msg="floating glass dock must not change table height: \{tbl_h_before} -> \{tbl_h_selected}",
  )
  assert_true(t.query(Checkbox, label="取消全选") is Some(_), msg="master checkbox label flips to 取消全选 when all selectable rows picked")
  assert_true(t.query(Button, label="共享") is Some(_), msg="floating batch dock appears with 共享 after select-all")
  assert_true(t.query(Button, label="刷新") is Some(_), msg="floating batch dock shows direct 刷新 button")
  assert_true(t.query(Button, label="删除") is Some(_), msg="floating batch dock shows direct 删除 button")
  t.click(Checkbox, label="取消全选")
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Checkbox, label="全选") is Some(_), msg="master checkbox resets to 全选 after toggling off")
  assert_true(t.query(Button, label="刷新") is None, msg="floating batch dock hides when selection cleared")
  // 2. Switching to 白名单 filter via sharing dropdown when whitelist is empty shows both filter-empty and the conditional whitelist hint.
  t.click(Button, label="全部共享")
  presented_in(t)
  t.click(MenuItemCheckbox, label="白名单")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("当前筛选下没有账号") is Some(_), msg="filter-empty shown when no rows match filter")
  assert_true(t.find("白名单暂无 station") is Some(_), msg="conditional whitelist hint appears on 白名单 filter when whitelist is empty")
  assert_true(t.query(Checkbox, label="全选") is None, msg="table header omitted when filtered list is empty")
  // 3. Narrow 320pt 1.3x English: wrapped batch dock still clears the last scrolled row with 0 audit/corner faults.
  let tn = setting_tester(ProfilesManage(""), 320.0, platform=2, h=640.0, over=fn(s) { with_share_auto(s) })
  @sf.set_language(Some("en"))
  tn.set_font_scale(1.3)
  tn.run_for(@ui.move_most_ms)
  tn.click(Checkbox, label="Claude 主账号")
  tn.run_for(@ui.move_most_ms)
  tn.click(Checkbox, label="ChatGPT 团队")
  tn.run_for(@ui.move_most_ms)
  assert_eq(tn.corner_faults(), [], msg="320pt 1.3x en corner faults")
  assert_eq(tn.first_line_faults(), [], msg="320pt 1.3x en first_line faults")
  assert_eq(tn.fixed_outgrown(), [], msg="320pt 1.3x en outgrown")
  assert_eq(tn.squeeze_faults(), [], msg="320pt 1.3x en squeeze")
  assert_eq(tn.words_over_now(), [], msg="320pt 1.3x en words_over")
  for _ in 0..<14 {
    tn.wheel(160.0, 200.0, 200.0)
  }
  tn.run_for(@ui.move_most_ms)
  let dock_top = tn.drawn_glass().filter(fn(gl) { gl.1 + gl.3 > 400.0 && gl.2 > 180.0 })[0].1
  guard tn.query(Checkbox, label="备用 key") is Some(last_cb) else {
    @sf.set_language(None)
    fail("320pt 1.3x en last row (备用 key) not found after scrolling")
  }
  assert_true(
    last_cb.rect.1 + last_cb.rect.3 <= dock_top,
    msg="320pt 1.3x en last row bottom \{last_cb.rect.1 + last_cb.rect.3} must be <= dock_top \{dock_top}",
  )
  @sf.set_language(None)
  // 4. Wide table with an unshareable 2-line row (`why_text != ""`) has 0 first_line_faults.
  let with_unshareable = fn(base : Source) {
    let s = with_share_auto(base)
    {
      ..s,
      topic_read: fn(name, params) {
        let v = s.topic(name, params).get().snapshot()
        if name == "profiles" {
          match v.value {
            Some(Object(o)) => {
              let m = o.copy()
              let its = items(v.value, "items").map(fn(r) {
                if text(field(Some(r), "profile"), "id") == "cc" {
                  match r {
                    Object(ro) => {
                      let rm = ro.copy()
                      rm["canBatchShare"] = Json::boolean(false)
                      rm["batchShareWhy"] = Json::string("unshareable")
                      Json::object(rm)
                    }
                    _ => r
                  }
                } else {
                  r
                }
              })
              m["items"] = Json::array(its)
              { ..v, value: Some(Json::object(m)) }
            }
            _ => v
          }
        } else {
          v
        }
      },
    }
  }
  let tw = setting_tester(ProfilesManage(""), 900.0, platform=0, h=800.0, over=with_unshareable)
  tw.run_for(@ui.move_most_ms)
  assert_eq(tw.first_line_faults(), [], msg="wide 2-line unshareable row first_line faults")
  assert_eq(tw.corner_faults(), [], msg="wide 2-line unshareable row corner faults")
}

///|
test "批量管理 status column (pm_status_of), health/type filters, and group filter auto-reset" {
  @sfbase.reset()
  @sf.set_words(@sfbase.fill)
  // 1. Direct pm_status_of / pm_row_has_issue coverage across state, usable, look, scoped vs account-wide windows, and core level.
  let state_red = obj([
    ("usable", Json::boolean(false)),
    ("state", obj([("text", str("需要登录")), ("tone", str("red"))])),
  ])
  assert_eq(pm_status_of(Some(state_red)), ("需要登录", "red"))
  assert_true(pm_row_has_issue(state_red))

  let unusable_no_state = obj([("usable", Json::boolean(false))])
  assert_eq(pm_status_of(Some(unusable_no_state)), ("需关注", "red"))
  assert_true(pm_row_has_issue(unusable_no_state))

  let look_no_state = obj([("usable", Json::boolean(true)), ("look", Json::boolean(true))])
  assert_eq(pm_status_of(Some(look_no_state)), ("需关注", "amber"))
  assert_true(pm_row_has_issue(look_no_state))

  // Scoped single-model window (Fable 0% red) is ignored when account-wide windows exist.
  let with_scoped_fable = obj([
    ("usable", Json::boolean(true)),
    ("profile", obj([
      ("quota", obj([
        ("state", str("ok")),
        ("windows", Json::array([
          obj([("mark", str("5H")), ("left", Json::number(80.0)), ("level", str("ok"))]),
          obj([("mark", str("W")), ("left", Json::number(60.0)), ("level", str("ok"))]),
          obj([("mark", str("Fable")), ("scope", str("Fable")), ("left", Json::number(0.0)), ("level", str("red"))]),
        ])),
      ])),
    ])),
  ])
  assert_eq(pm_status_of(Some(with_scoped_fable)), ("W 60%", "ok"))
  assert_false(pm_row_has_issue(with_scoped_fable))

  // When every window has a scope (e.g. Antigravity), fall back to all windows and obey core's red level.
  let all_scoped = obj([
    ("usable", Json::boolean(true)),
    ("profile", obj([
      ("quota", obj([
        ("state", str("ok")),
        ("windows", Json::array([
          obj([("mark", str("Gemini 5H")), ("scope", str("Gemini")), ("left", Json::number(15.0)), ("level", str("amber"))]),
          obj([("mark", str("Claude / GPT 5H")), ("scope", str("Claude / GPT")), ("left", Json::number(0.0)), ("level", str("red"))]),
        ])),
      ])),
    ])),
  ])
  assert_eq(pm_status_of(Some(all_scoped)), ("5H 0%", "red"))
  assert_true(pm_row_has_issue(all_scoped))

  // Empty windows on a usable profile show 正常 (ok).
  let empty_ws = obj([
    ("usable", Json::boolean(true)),
    ("profile", obj([("quota", obj([("state", str("ok")), ("windows", Json::array([]))]))])),
  ])
  assert_eq(pm_status_of(Some(empty_ws)), ("正常", "ok"))
  assert_false(pm_row_has_issue(empty_ws))

  // API key with creditsText displays credits rather than generic 正常.
  let with_credits = obj([
    ("usable", Json::boolean(true)),
    ("group", str("key")),
    ("profile", obj([("quota", obj([("state", str("ok")), ("windows", Json::array([])), ("creditsText", str("余额 $42.80"))]))])),
  ])
  assert_eq(pm_status_of(Some(with_credits)), ("余额 $42.80", "ok"))
  assert_false(pm_row_has_issue(with_credits))

  // Grouping keeps provider groups in order while sorting rows within each group.
  let g_claude_b = obj([("key", str("c2")), ("group", str("claude")), ("groupTitle", str("Claude 订阅")), ("profile", obj([("name", str("Claude 团队"))]))])
  let g_claude_a = obj([("key", str("c1")), ("group", str("claude")), ("groupTitle", str("Claude 订阅")), ("profile", obj([("name", str("Claude 主账号"))]))])
  let g_key_a = obj([("key", str("k1")), ("group", str("key")), ("groupTitle", str("API key")), ("profile", obj([("name", str("Anthropic API"))]))])
  let grouped_sorted = pm_grouped_rows([g_claude_b, g_key_a, g_claude_a], Some({ col: "account", dir: Asc }), [])
  assert_eq(grouped_sorted.length(), 2)
  assert_eq(grouped_sorted[0].0, "claude")
  assert_eq(grouped_sorted[0].1, "Claude 订阅")
  assert_eq(grouped_sorted[0].2.map(fn(r) { text(Some(r), "key") }), ["c1", "c2"])
  assert_eq(grouped_sorted[1].0, "key")
  assert_eq(grouped_sorted[1].2.map(fn(r) { text(Some(r), "key") }), ["k1"])

  // 2. Live UI: type dropdown filters by group and auto-resets to 全部类型 when that group disappears; status dropdown filters 正常 vs 需关注.
  let drop_codex : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })
  let t = setting_tester(ProfilesManage(""), 1100.0, platform=0, h=800.0, over=fn(base) {
    let s = with_share_auto(base)
    {
      ..s,
      topic_read: fn(name, params) {
        let v = s.topic(name, params).get().snapshot()
        if name == "profiles" {
          let hide = drop_codex.get()
          match v.value {
            Some(Object(o)) => {
              let m = o.copy()
              let its = items(v.value, "items").filter_map(fn(r) {
                let pname = text(field(Some(r), "profile"), "name")
                if hide && text(Some(r), "group") == "chatgpt" {
                  None
                } else if pname == "备用 key" {
                  match r {
                    Object(ro) => {
                      let rm = ro.copy()
                      rm["usable"] = Json::boolean(false)
                      rm["state"] = obj([("text", str("key 已失效")), ("tone", str("red"))])
                      Some(Json::object(rm))
                    }
                    _ => Some(r)
                  }
                } else if pname == "Claude 主账号" {
                  match r {
                    Object(ro) => {
                      let rm = ro.copy()
                      rm["usable"] = Json::boolean(true)
                      rm["look"] = Json::boolean(false)
                      rm.remove("state")
                      match field(Some(r), "profile") {
                        Some(Object(po)) => {
                          let pm = po.copy()
                          pm["quota"] = obj([
                            ("state", str("ok")),
                            ("windows", Json::array([obj([("mark", str("W")), ("left", Json::number(80.0)), ("level", str("ok"))])])),
                          ])
                          rm["profile"] = Json::object(pm)
                        }
                        _ => ()
                      }
                      Some(Json::object(rm))
                    }
                    _ => Some(r)
                  }
                } else {
                  Some(r)
                }
              })
              m["items"] = Json::array(its)
              { ..v, value: Some(Json::object(m)) }
            }
            _ => v
          }
        } else {
          v
        }
      },
    }
  })
  t.run_for(@ui.move_most_ms)
  // Filter by status = 需关注 shows 备用 key (key 已失效) and hides healthy Claude 主账号.
  t.click(Button, label="全部状态")
  presented_in(t)
  t.click(MenuItemCheckbox, label="需关注")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("备用 key") is Some(_) && t.find("key 已失效") is Some(_), msg="需关注 filter keeps red row")
  assert_true(t.find("Claude 主账号") is None, msg="需关注 filter hides healthy row")
  t.click(Button, label="需关注")
  presented_in(t)
  t.click(MenuItemCheckbox, label="正常")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("Claude 主账号") is Some(_), msg="正常 filter keeps healthy row")
  assert_true(t.find("备用 key") is None, msg="正常 filter hides red row")
  t.click(Button, label="正常")
  presented_in(t)
  t.click(MenuItemCheckbox, label="全部状态")
  t.run_for(@ui.move_most_ms)
  // Type dropdown filters to ChatGPT 订阅 and auto-resets to 全部类型 when its rows disappear.
  t.click(Button, label="全部类型")
  presented_in(t)
  t.click(MenuItemCheckbox, label="ChatGPT 订阅")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("ChatGPT 团队") is Some(_), msg="type filter keeps ChatGPT row")
  assert_true(t.find("Claude 主账号") is None, msg="type filter hides non-ChatGPT row")
  drop_codex.set(true)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="全部类型") is Some(_), msg="type filter auto-resets to 全部类型 when selected group disappears")
  assert_true(t.find("Claude 主账号") is Some(_), msg="rows reappear after type filter auto-reset")
}

///|
test "批量管理 set_max_sessions_many validation, skip, partial failure, still_here, and reactive wide-narrow dock resize" {
  @sfbase.reset()
  @sf.set_words(@sfbase.fill)
  // 1. Direct parser checks matching ask_max_sessions.
  assert_eq(parse_max_sessions(""), Some(Json::null()))
  assert_eq(parse_max_sessions("  0  "), Some(Json::null()))
  assert_eq(parse_max_sessions("5"), Some(Json::number(5.0)))
  assert_eq(parse_max_sessions("-1"), None)
  assert_eq(parse_max_sessions("abc"), None)
  assert_eq(parse_max_sessions("00"), None)
  assert_eq(parse_max_sessions("1234567890"), None)

  // 2. Batch set_max_sessions_many via ⋯ menu: invalid input sends 0 RPCs; valid input skips unsupported API key row;
  //    blank sends null; partial failure keeps failed selection; still_here=false suppresses toast.
  let asked : Array[(String, Json)] = []
  let fail_id : Ref[String] = Ref("")
  let hold_cb : Ref[((Result[Json, Json]) -> Unit)?] = Ref(None)
  let win_w : @signals.Signal[Double] = @signals.signal(1100.0, same=fn(a, b) { a == b })
  let t = setting_tester(ProfilesManage(""), 1100.0, platform=0, h=800.0, width=fn() { win_w.get() }, over=fn(base) {
    let s = with_share_auto(base)
    {
      ..s,
      call: fn(name, params, done) {
        if name == "profile.put" {
          asked.push((name, params))
          let id = text(Some(params), "id")
          if fail_id.val == "HOLD" {
            hold_cb.val = Some(done)
          } else if fail_id.val != "" && id == fail_id.val {
            done(Err(obj([("message", str("boom"))])))
          } else {
            done(Ok(obj([])))
          }
        } else {
          (s.call)(name, params, done)
        }
      },
    }
  })
  t.run_for(@ui.move_most_ms)
  // Select subscription (Claude 主账号, supports cap) + API key (备用 key, unsupported).
  t.click(Checkbox, label="Claude 主账号")
  t.click(Checkbox, label="备用 key")
  t.run_for(@ui.move_most_ms)

  // 2a. Reactive wide -> narrow -> wide dock layout without rebuilding or leaving corner faults.
  let clear_w = t.get(Button, label="清空").rect
  let share_w = t.get(Button, label="共享").rect
  assert_true((clear_w.1 - share_w.1).abs() < 8.0, msg="wide dock keeps 清空 and 共享 on one row")
  assert_eq(t.corner_faults(), [], msg="wide dock 0 corner faults")
  win_w.set(390.0)
  t.resize(390.0, 800.0)
  t.run_for(@ui.move_most_ms)
  let clear_n = t.get(Button, label="清空").rect
  let share_n = t.get(Button, label="共享").rect
  assert_true(share_n.1 > clear_n.1 + 12.0, msg="narrow dock reactively flips to two rows on resize")
  assert_eq(t.corner_faults(), [], msg="narrow dock after wide->narrow resize has 0 corner faults")
  win_w.set(1100.0)
  t.resize(1100.0, 800.0)
  t.run_for(@ui.move_most_ms)
  let clear_w2 = t.get(Button, label="清空").rect
  let share_w2 = t.get(Button, label="共享").rect
  assert_true((clear_w2.1 - share_w2.1).abs() < 8.0, msg="dock reactively flips back to one row on narrow->wide resize")
  assert_eq(t.corner_faults(), [], msg="wide dock after narrow->wide resize has 0 corner faults")

  // 2b. Invalid input "abc" shows invalid toast and sends 0 profile.put calls.
  t.click(Button, label="更多操作")
  presented_in(t)
  t.click(MenuItem, label="并发上限")
  presented_in(t)
  assert_true(t.find("跳过 1 个不支持并发上限的账号") is Some(_), msg="dialog hint explains skipped unsupported row")
  t.type_text("abc")
  t.click(Button, label="保存")
  t.run_for(@motion.presence_out_ms)
  assert_eq(asked.length(), 0, msg="invalid cap must send 0 RPCs")
  assert_eq(@sfbase.toast_words(), @sf.t("web-pages.profiles.maxConcurrentSessionsInvalid"), msg="invalid cap emits invalid toast")

  // 2c. Valid input "5" updates only eligible subscription row and reports skipped count.
  t.click(Button, label="更多操作")
  presented_in(t)
  t.click(MenuItem, label="并发上限")
  presented_in(t)
  t.type_text("5")
  t.click(Button, label="保存")
  t.run_for(@motion.presence_out_ms)
  assert_eq(asked.length(), 1, msg="only eligible profile receives profile.put")
  assert_eq(text(Some(asked[0].1), "id"), "cc")
  assert_eq(field(field(Some(asked[0].1), "input"), "maxConcurrentSessions"), Some(Json::number(5.0)))
  assert_true(@sfbase.toast_words().contains("跳过 1 个不支持的账号"), msg="completion toast mentions skipped count: " + @sfbase.toast_words())
  // Wide batch dock is a flow child (`ComeGroup` collapse animation); wait for collapse before checking DOM removal.
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("已选 ") is None, msg="selection clears after full success")

  // 2d. Input "0" clears to null, and partial failure keeps only the failed row ticked.
  asked.clear()
  fail_id.val = "cx"
  t.click(Checkbox, label="Claude 主账号")
  t.click(Checkbox, label="ChatGPT 团队")
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="更多操作")
  presented_in(t)
  t.click(MenuItem, label="并发上限")
  presented_in(t)
  t.type_text("0")
  t.click(Button, label="保存")
  t.run_for(@motion.presence_out_ms)
  assert_eq(asked.length(), 2, msg="both subscription rows receive profile.put")
  assert_eq(field(field(Some(asked[0].1), "input"), "maxConcurrentSessions"), Some(Json::null()))
  assert_true(t.find("已选 1 项") is Some(_), msg="partial failure retains failed selection")
  assert_eq(t.get(Checkbox, label="ChatGPT 团队").check, Some(On), msg="failed row remains checked")
  assert_eq(t.get(Checkbox, label="Claude 主账号").check, Some(Off), msg="succeeded row is unchecked")

  // 2e. still_here turning false while in-flight suppresses completion toast.
  fail_id.val = "HOLD"
  t.click(Button, label="更多操作")
  presented_in(t)
  t.click(MenuItem, label="并发上限")
  presented_in(t)
  t.type_text("3")
  t.click(Button, label="保存")
  t.run_for(@motion.presence_out_ms)
  t.click(Link, label="设置")
  t.run_for(@ui.move_most_ms)
  let toast_n_before = @signals.untracked(fn() { app.toast.get().n })
  match hold_cb.val {
    Some(cb) => cb(Ok(obj([])))
    None => fail("expected held profile.put callback")
  }
  t.run_for(@ui.move_most_ms)
  assert_eq(@signals.untracked(fn() { app.toast.get().n }), toast_n_before, msg="completion after leaving page must not emit toast")
}
