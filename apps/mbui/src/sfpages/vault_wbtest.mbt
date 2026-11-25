// 密钥 (vault.mbt, vault_item.mbt, vault_dialogs.mbt) alone, at each width, with a finger and with a mouse: the
// request waiting as its card, how its secrets are kept a row each (encrypted, the longest a grant lasts, its choices
// through the presenters, the devices holding its key), 全部密钥 a row to its secrets' page; there its secrets, a row
// each of one list found by their words, and 添加 through the presenters.

///|
test "密钥, at each width and with either hand: the request's card, encrypted, the longest grant; its secrets a page under it" {
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(Vault, w, platform~)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("git push origin main") is Some(_), msg=at)
    // (what it keeps: a page under it, adding there)
    assert_true(t.find("部署机") is None, msg=at)
    assert_true(page_add(t) is None, msg=at)
    // how it is kept, a row each: encrypted, the longest grant the one now under it, the devices holding its key
    scrolled_to(t, w, "默认最长授权")
    for words in ["已加密", "仅你的设备可解密", "默认最长授权", "直到对话归档", "2 台设备已授权"] {
      assert_true(t.find(words) is Some(_), msg="\{at}: \{words}")
    }
    // its choices, each with what it means, through the presenters (none of them on the page itself)
    assert_true(t.find("每次使用都要你批准一次") is None, msg=at)
    let (lx, ly) = t.find("默认最长授权").unwrap()
    t.tap(lx, ly)
    t.frame()
    assert_true(@sf.presenting(), msg=at)
    presented_in(t)
    assert_true(t.find("每次使用都要你批准一次") is Some(_), msg=at)
    @sf.close_presented()
    t.frame()
    // 全部密钥 pressed: its page (made once as nodes, which this old view's Tester does not draw: what it holds, and 添加,
    // its own test's)
    scrolled_to(t, w, "全部密钥")
    tap_words(t, "全部密钥")
    t.frame()
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() == Setting(VaultItems), msg=at)
  }
}

///|
test "密钥, at each width and with either hand, a vault of the viewer's waiting to be keyed anew: said on a card under its name, on which station, read meanwhile and not changed; 全部密钥 there still" {
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(Vault, w, platform~, mode="settings-vault-waits")
    let at = "\{w} platform \{platform}"
    let said = "有设备被移除。你的设备连上 station「Willow」后会自动换好；在这之前照常能查看和使用，不能修改"
    scrolled_to(t, w, said)
    t.run_for(@ui.move_most_ms)
    for words in ["等待换钥匙", said] {
      assert_true(t.find(words) is Some(_), msg="\{at}: \{words}")
    }
    scrolled_to(t, w, "全部密钥")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("全部密钥") is Some(_), msg=at)
    let faults = t.audit()
    assert_true(faults.is_empty(), msg=at + ": " + faults.join(" | "))
  }
}

///|
test "密钥, at each width and with either hand, this device to be verified once: why, and 验证 asking lock.confirmSigner once, a ring on it meanwhile; then the library" {
  for case in page_cases {
    let (w, platform) = case
    let asked : Array[(String, Json)] = []
    let answers : Array[(Result[Json, Json]) -> Unit] = []
    let t = setting_tester(Vault, w, platform~, mode="settings-vault-confirm", over=fn(base) {
      {
        ..base,
        call: fn(name, params, done) {
          if name == "lock.confirmSigner" {
            asked.push((name, params))
            @settings.fixture_lock_doing(name, params) |> ignore
            answers.push(done)
          } else {
            (base.call)(name, params, done)
          }
        },
      }
    })
    t.run_for(@ui.move_most_ms)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("此设备需完成一次验证后才能使用密钥库") is Some(_), msg=at)
    // (not the way to 安全, where nothing would end it)
    assert_true(t.find("去安全设置") is None, msg=at)
    let faults = t.audit()
    assert_true(faults.is_empty(), msg=at + ": " + faults.join(" | "))
    tap_words(t, "验证")
    t.frame()
    tap_words(t, "验证")
    t.run_for(@ui.move_most_ms)
    assert_eq(asked.length(), 1, msg=at)
    assert_eq(asked[0].1, { "workspace": "ws1" }, msg=at)
    @settings.fixture_lock_done()
    answers[0](Ok(Json::null()))
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("此设备需完成一次验证后才能使用密钥库") is None, msg=at)
    assert_true(t.find("git push origin main") is Some(_), msg=at)
  }
}

///|
test "密钥, at each width and with either hand, the members still syncing: what it waits for, nothing to press" {
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(Vault, w, platform~, mode="settings-vault-syncing")
    t.run_for(@ui.move_most_ms)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("正在同步安全模式的成员名单，同步完成后即可使用") is Some(_), msg=at)
    assert_true(t.find("去安全设置") is None, msg=at)
    assert_true(t.find("验证") is None, msg=at)
    let faults = t.audit()
    assert_true(faults.is_empty(), msg=at + ": " + faults.join(" | "))
  }
}

///|
test "全部密钥, at each width and with either hand: 添加 asks what; every secret a row of one list, its kind and what is worth knowing of it under its name; the profiles' accounts folded at its foot; found by any of their words" {
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(VaultItems, w, platform~)
    let at = "\{w} platform \{platform}"
    // 添加 at its head asks what (through the presenters)
    assert_false(@sf.presenting(), msg=at)
    let (x, y, bw, bh) = page_add(t).unwrap().rect
    t.tap(x + bw / 2.0, y + bh / 2.0)
    t.frame()
    assert_true(@sf.presenting(), msg=at)
    @sf.close_presented()
    t.frame()
    t.run_for(@ui.move_most_ms)
    // (a secret: its kind, how an agent gets it, when and where it was last used)
    for words in ["GitHub token", "Token · 代理 · api.github.com · 昨天在「修 CI」用过", "SSH 密钥 · ssh-agent", "订阅和 API Key", "Claude 主账号、ChatGPT 团队、备用 key"] {
      assert_true(t.find(words) is Some(_), msg="\{at}: \{words}")
    }
    // the accounts folded till their row (naming them) is pressed: no row of theirs
    assert_true(t.find("Claude 订阅 · Willow 可用") is None, msg=at)
    scrolled_to(t, w, "订阅和 API Key")
    tap_words(t, "订阅和 API Key")
    t.frame()
    scrolled_to(t, w, "Claude 订阅 · Willow 可用")
    for words in ["Claude 主账号", "Claude 订阅 · Willow 可用"] {
      assert_true(t.find(words) is Some(_), msg="\{at}: \{words}")
    }
    // found: 部署机 by its way, nothing else
    t.wheel(w / 2.0, 450.0, -3000.0)
    t.frame()
    let (fx, fy) = t.find("搜索名称、域名、变量名").unwrap()
    t.tap(fx + 4.0, fy + 4.0)
    t.frame()
    t.type_text("ssh")
    // (what is not found closing where it was, the rest coming up as it does: @sf.group_rows)
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("部署机") is Some(_), msg=at)
    for gone in ["GitHub token", "Claude", "订阅和 API Key"] {
      assert_true(t.find(gone) is None, msg="\{at}: \{gone}")
    }
    t.type_text("zz")
    t.frame()
    assert_true(t.find("没有找到「sshzz」") is Some(_), msg=at)
  }
}

///|
test "a secret's page, at each width and with either hand: what it is and where, its content masked, how agents use it, 编辑" {
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(VaultItem("v1", "it1"), w, platform~)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("GitHub token") is Some(_), msg=at)
    assert_true(t.find("内容") is Some(_), msg=at)
    assert_true(t.query(Button, label="编辑") is Some(_), msg=at)
    scrolled_to(t, w, "代理 · 限 api.github.com")
    assert_true(t.find("代理 · 限 api.github.com") is Some(_), msg=at)
  }
}

///|
test "secrets left in plain text from before security mode: how many, 加密 encrypting them into the vault" {
  let t = setting_tester(Vault, 390.0, platform=2, mode="settings-vault-plain")
  scrolled_to(t, 390.0, "2 条密钥尚未加密")
  assert_true(t.find("2 条密钥尚未加密") is Some(_))
  // (its row pressed: 加密 where it says what it does, the last words with 加密 in them as the title says it too)
  let (x, y) = t.find_last("加密").unwrap()
  t.tap(x, y)
  // (leaving row rests with its frozen "2 条密钥尚未加密" text while closing, never flashing "0 条密钥尚未加密")
  assert_true(t.find("0 条密钥尚未加密") is None)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("2 条密钥尚未加密") is None)
}

///|
test "密钥: 默认最长授权 a row over the profiles' keys, the one now under it; pressed, its three choices, each with what it means (Vault.kt DefaultLasts)" {
  let t = setting_tester(Vault, 390.0, platform=2)
  scrolled_to(t, 390.0, "默认最长授权")
  assert_true(t.find("直到对话归档") is Some(_))
  assert_true(t.find("每次使用都要你批准一次") is None)
  let (x, y) = t.find("默认最长授权").unwrap()
  t.tap(x, y)
  t.frame()
  presented_in(t)
  for words in ["仅一次", "1 小时", "每次使用都要你批准一次", "最长能选「本对话直到归档」，至多 30 天"] {
    assert_true(t.find(words) is Some(_), msg=words)
  }
}

///|
/// 添加 at the page's head (not a phone's bottom bar's, at the window's foot).
fn page_add(t : @ui.Tester) -> @ui.SemNode? {
  for s in t.all(Button, label="添加") {
    if s.rect.1 < 450.0 {
      return Some(s)
    }
  }
  None
}

///|
/// What was just presented, in: a sheet (with a finger short of the Large tier) at rest; a panel by what opened it or
/// a dialog (with a pointer) past its coming.
fn presented_in(t : @ui.Tester) -> Unit {
  let rest = @sf.presented_rest()
  t.run_for(if rest > t.time() { rest - t.time() } else { @ui.move_most_ms })
}

///|
test "全部密钥's 添加 as the page is given another width: the same button while its arrangement stays (wide, its words after its mark; narrow, its mark alone, round)" {
  for case in [(1280.0, 1100.0, 0), (390.0, 360.0, 2)] {
    let (w, other, platform) = case
    let width = @signals.signal(w)
    let t = setting_tester(VaultItems, w, platform~, width=fn() { width.get() })
    let at = "\{w} platform \{platform}"
    let first = page_add(t).unwrap()
    let (_, _, bw, bh) = first.rect
    if laid_wide(w) {
      assert_true(bw > bh + 8.0, msg="\{at}: its words after its mark: \{bw}x\{bh}")
    } else {
      assert_eq(bw, bh, msg="\{at}: its mark alone, round")
    }
    for now in [other, w] {
      width.set(now)
      t.resize(now, 900.0)
      t.run_for(@ui.move_most_ms)
      assert_eq(page_add(t).unwrap().id, first.id, msg="\{at} to \{now}: the same button")
    }
  }
}

///|
/// 密钥 with no safe mode, at Small (390×844), narrow with words at 1.3 (320×640) and Large (1280×800): not turned on
/// (开启 its one press), turned on with secrets from before to encrypt, this device to be approved by another trusted
/// device of the person's on the page itself (its code typed there; their devices set up again elsewhere said to be
/// theirs), never sent off to 安全; each with nothing the audit finds, and no word for the lock of one's own.
test "密钥 with no safe mode: 开启, what is left to encrypt, this device approved on the page itself; nothing the audit finds" {
  let sizes : Array[(Double, Double, Int, Double)] = [(390.0, 844.0, 2, 1.0), (320.0, 640.0, 2, 1.3), (1280.0, 800.0, 0, 1.0)]
  let cases : Array[(String, Array[String], Array[String])] = [
    ("settings-vault-own-off", ["密钥库未开启", "开启密钥库"], ["去安全设置"]),
    ("settings-vault-own-on", ["2 条密钥尚未加密", "加密"], ["去安全设置"]),
    ("settings-vault-own-outside", ["此设备尚未获批", "在你的受信任设备上批准这台设备后，即可在此使用密钥库。", "发送批准请求", "Pixel 9 · youdid.wtf Android", "林的 MacBook Pro · monoid 桌面版"], ["去安全设置"]),
    ("settings-vault-own-finding", ["此设备尚未获批", "正在找你的其它设备，请打开其中一台的 still.fail app", "Pixel 9 · youdid.wtf Android", "林的 MacBook Pro · monoid 桌面版"], ["去安全设置", "发送批准请求"]),
    ("settings-vault-own-code", ["此设备尚未获批"], ["去安全设置", "发送批准请求", "Pixel 9 · youdid.wtf Android", "林的 MacBook Pro · monoid 桌面版"]),
    ("settings-vault-own-replaced", ["你的受信任设备被重新设置过", "是我做的，继续"], ["去安全设置"]),
  ]
  for size in sizes {
    let (w, h, platform, scale) = size
    for c in cases {
      let (mode, shown, not_shown) = c
      let t = setting_tester(Vault, w, platform~, mode~, h~)
      t.set_font_scale(scale)
      t.frame()
      t.run_for(@ui.move_most_ms)
      let at = "\{mode} \{w}×\{h} @\{scale}"
      for words in shown {
        if words == "2 条密钥尚未加密" || words == "加密" {
          scrolled_to(t, w, words)
        }
        assert_true(t.find(words) is Some(_), msg="\{at}: \{words}")
      }
      for words in not_shown {
        assert_true(t.find(words) is None, msg="\{at}: not \{words}")
      }
      for drawn in t.words() {
        assert_true(!drawn.0.contains("个人锁") && !drawn.0.contains("共享调试"), msg="\{at}: \{drawn.0}")
      }
      let faults = t.audit()
      assert_true(faults.is_empty(), msg=at + ": " + faults.join(" | "))
    }
  }
}

///|
test "not set up here: 密钥库未开启 only while no vault of theirs is on anywhere; one on on another device of theirs, the library with it under its name, no key here yet" {
  let off = Json::object(Map::from_array([("available", Json::boolean(true)), ("canSign", Json::boolean(true)), ("setUp", Json::boolean(false)), ("vaults", Json::array([]))]))
  assert_true(vault_first_keys("ws1", Some(off)) == Some(["off"]))
  let row = Json::object(Map::from_array([("id", Json::string("v1")), ("name", Json::string("个人")), ("keyed", Json::boolean(false))]))
  let elsewhere = Json::object(Map::from_array([("available", Json::boolean(true)), ("canSign", Json::boolean(true)), ("setUp", Json::boolean(false)), ("vaults", Json::array([row]))]))
  assert_true(vault_first_keys("ws1", Some(elsewhere)) is None)
  assert_true(vault_library_keys(Some(elsewhere)).contains("no-key/v1"))
  // (on the page: the vault under its name, 申请授权 there; never 密钥库未开启, nor 开启密钥库)
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(Vault, w, platform~, mode="settings-vault-elsewhere")
    t.run_for(@ui.move_most_ms)
    let at = "\{w} platform \{platform}"
    for words in ["林的库", "此设备未获此库授权", "申请授权"] {
      assert_true(t.find(words) is Some(_), msg="\{at}: \{words}")
    }
    for words in ["密钥库未开启", "开启密钥库"] {
      assert_true(t.find(words) is None, msg="\{at}: not \{words}")
    }
    let faults = t.audit()
    assert_true(faults.is_empty(), msg=at + ": " + faults.join(" | "))
  }
}

///|
test "workspace vault create card emits vault.create with scope workspace" {
  let calls : Array[(String, Json)] = []
  let t = setting_tester(Vault, 1100.0, platform=0, mode="settings-vault-workspace-create", over=fn(base) {
    {
      ..base,
      call: fn(name, params, done) {
        calls.push((name, params))
        (base.call)(name, params, done)
      },
    }
  })
  t.run_for(@ui.move_most_ms)
  scrolled_to(t, 1100.0, "创建 Workspace 密钥库")
  assert_true(t.find("Workspace 密钥库") is Some(_))
  tap_words(t, "创建 Workspace 密钥库")
  t.run_for(@ui.move_most_ms)
  let created = calls.filter(fn(c) { c.0 == "vault.create" })
  assert_eq(created.length(), 1)
  assert_eq(created[0].1, { "workspace": "ws1", "name": "Workspace 密钥库", "scope": "workspace" })
}

///|
test "workspace vault members dialog toggles member, shows rekey warning, and emits vault.setMembers" {
  let calls : Array[(String, Json)] = []
  let t = setting_tester(Vault, 1100.0, platform=0, mode="settings-vault-workspace", over=fn(base) {
    {
      ..base,
      call: fn(name, params, done) {
        calls.push((name, params))
        (base.call)(name, params, done)
      },
    }
  })
  t.run_for(@ui.move_most_ms)
  scrolled_to(t, 1100.0, "共享成员")
  assert_true(t.find("3 位成员") is Some(_))
  tap_words(t, "共享成员")
  t.frame()
  presented_in(t)
  assert_true(t.find("Workspace 密钥库成员") is Some(_))
  assert_true(t.find("移除成员后将自动更换密钥库主密钥并重新加密所有条目。") is None)
  // verify VaultMember object array [{ sub, name }] initializes all 3 switches to On
  assert_eq(t.get(Switch, label="林").check, Some(On))
  assert_eq(t.get(Switch, label="Ana").check, Some(On))
  assert_eq(t.get(Switch, label="周").check, Some(On))
  // uncheck 周 (u3)
  t.click(Switch, label="周")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("移除成员后将自动更换密钥库主密钥并重新加密所有条目。") is Some(_))
  t.click(Button, label="保存")
  t.run_for(@ui.move_most_ms)
  let saved = calls.filter(fn(c) { c.0 == "vault.setMembers" })
  assert_eq(saved.length(), 1)
  assert_eq(saved[0].1, { "workspace": "ws1", "vault": "v-ws", "members": ["u1", "u2"] })
}

///|
test "vault editor dialog switches target to workspace vault and emits vault.putItem for v-ws" {
  let calls : Array[(String, Json)] = []
  let t = setting_tester(VaultItems, 1100.0, platform=0, mode="settings-vault-workspace", over=fn(base) {
    {
      ..base,
      call: fn(name, params, done) {
        calls.push((name, params))
        (base.call)(name, params, done)
      },
    }
  })
  t.run_for(@ui.move_most_ms)
  let (x, y, bw, bh) = page_add(t).unwrap().rect
  t.tap(x + bw / 2.0, y + bh / 2.0)
  t.frame()
  presented_in(t)
  tap_words(t, "Token")
  t.frame()
  presented_in(t)
  assert_true(t.find("保存到") is Some(_))
  tap_words(t, "Workspace 密钥库")
  t.frame()
  t.click(TextField, label="名称")
  t.frame()
  t.type_text("Team API Key")
  t.click(TextField, label="值")
  t.frame()
  t.type_text("ghp_team123")
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="保存")
  t.run_for(@ui.move_most_ms)
  let put = calls.filter(fn(c) { c.0 == "vault.putItem" })
  assert_eq(put.length(), 1)
  assert_eq(text(Some(put[0].1), "vault"), "v-ws")
}

///|
test "vault page save card defaults to personal vault and switches to workspace vault on chooser pick" {
  let calls : Array[(String, Json)] = []
  let t = setting_tester(Vault, 1100.0, platform=0, mode="settings-vault-workspace", over=fn(base) {
    {
      ..base,
      call: fn(name, params, done) {
        calls.push((name, params))
        (base.call)(name, params, done)
      },
    }
  })
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("Sentry DSN") is Some(_))
  assert_true(t.find("将存入团队共享密钥库「Workspace 密钥库」") is None)
  // open target vault chooser (default personal vault "林的库")
  tap_words(t, "林的库")
  t.run_for(@ui.move_most_ms)
  tap_words(t, "Workspace 密钥库")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("将存入团队共享密钥库「Workspace 密钥库」") is Some(_))
  tap_words(t, "存入")
  t.run_for(@ui.move_most_ms)
  let approved = calls.filter(fn(c) { c.0 == "vault.approve" })
  assert_eq(approved.length(), 1)
  assert_eq(text(Some(approved[0].1), "request"), "r-ws-save")
  assert_eq(text(Some(approved[0].1), "vault"), "v-ws")
}

///|
test "vault devices row opens per-device dialog, authorizes single device by exact id, and passes audit across widths and 1.3x" {
  let calls : Array[(String, Json)] = []
  let t = setting_tester(Vault, 1100.0, platform=0, mode="settings-vault-workspace", over=fn(base) {
    {
      ..base,
      call: fn(name, params, done) {
        calls.push((name, params))
        (base.call)(name, params, done)
      },
    }
  })
  t.run_for(@ui.move_most_ms)
  scrolled_to(t, 1100.0, "1 台新设备待授权")
  assert_true(t.find("1 台新设备待授权") is Some(_))
  // clicking the row opens the per-device dialog instead of blindly authorizing
  tap_words(t, "1 台新设备待授权")
  t.frame()
  presented_in(t)
  assert_true(@sf.presenting())
  assert_eq(calls.filter(fn(c) { c.0 == "vault.addDevice" }).length(), 0)
  for words in ["Workspace 密钥库 的设备", "待授权设备", "Pixel 9 · still.fail Android", "核对码 K7M-4PX", "已授权设备", "林的 MacBook Pro · still.fail（本机）", "Ana 的 MacBook Air · still.fail"] {
    assert_true(t.find(words) is Some(_), msg="missing: \{words}")
  }
  let faults = t.audit()
  assert_true(faults.is_empty(), msg="dialog desktop audit: " + faults.join(" | "))
  // click single-device authorize button
  t.click(Button, label="授权")
  t.run_for(@ui.move_most_ms)
  let added = calls.filter(fn(c) { c.0 == "vault.addDevice" })
  assert_eq(added.length(), 1)
  assert_eq(added[0].1, { "workspace": "ws1", "vault": "v-ws", "device": "d-new" })
  // device moves reactively from pending to authorized
  assert_true(t.find("待授权设备") is None)
  assert_true(t.find("Pixel 9 · still.fail Android") is Some(_))
  // narrow and 1.3x audit on the open dialog
  for size in [(390.0, 844.0, 2, 1.0), (390.0, 844.0, 2, 1.3)] {
    let (w, h, platform, scale) = size
    let t2 = setting_tester(Vault, w, platform~, mode="settings-vault-workspace", h~)
    t2.set_font_scale(scale)
    t2.frame()
    t2.run_for(@ui.move_most_ms)
    scrolled_to(t2, w, "1 台新设备待授权")
    tap_words(t2, "1 台新设备待授权")
    t2.frame()
    presented_in(t2)
    let f2 = t2.audit()
    assert_true(f2.is_empty(), msg="\{w}×\{h} @\{scale}: " + f2.join(" | "))
  }
}

///|
test "vault no-key card displays thisDeviceCode and passes audit across widths and 1.3x" {
  for size in [(1100.0, 760.0, 0, 1.0), (390.0, 844.0, 2, 1.0), (390.0, 844.0, 2, 1.3)] {
    let (w, h, platform, scale) = size
    let t = setting_tester(Vault, w, platform~, mode="settings-vault-no-key-code", h~)
    t.set_font_scale(scale)
    t.frame()
    t.run_for(@ui.move_most_ms)
    let at = "\{w}×\{h} @\{scale}"
    assert_true(t.find("本机核对码：") is Some(_), msg="\{at}: missing label")
    assert_true(t.find("K7M-4PX") is Some(_), msg="\{at}: missing code")
    let faults = t.audit()
    assert_true(faults.is_empty(), msg="\{at}: " + faults.join(" | "))
  }
}

///|
test "personal lock approval screen shows approver device names on initial/finding/none/failed, hides on code/wrong/checking, and wraps long names at 320px 1.3x" {
  let long_name = "研发部门测试专用超长设备名称 MacBook Pro 16-inch M5 Max Workstation · monoid 桌面版"
  let approvers : Json = Json::array([
    obj([("id", str("d-phone")), ("showing", Json::boolean(false)), ("kind", str("phone")), ("nameText", str("Pixel 9 · youdid.wtf Android"))]),
    obj([("id", str("d-long")), ("showing", Json::boolean(false)), ("kind", str("computer")), ("nameText", str(long_name))]),
  ])
  let make_adb = fn(pair : Json?) -> Json {
    let personal_fields : Array[(String, Json)] = [
      ("sub", str("s")),
      ("email", str("lin@example.com")),
      ("standing", str("outside")),
      ("devices", Json::array([])),
      ("approvers", approvers),
    ]
    match pair {
      Some(pv) => personal_fields.push(("pair", pv))
      None => ()
    }
    obj([("sharing", Json::boolean(false)), ("phase", str("off")), ("tunnels", Json::number(0.0)), ("personal", Json::array([obj(personal_fields)]))])
  }
  let states : Array[(String, Json?, Bool)] = [
    ("initial", None, true),
    ("finding", Some(obj([("state", str("finding")), ("devices", Json::number(0.0))])), true),
    ("none", Some(obj([("state", str("none")), ("devices", Json::number(0.0))])), true),
    ("failed", Some(obj([("state", str("failed")), ("devices", Json::number(0.0)), ("error", str("连接失败"))])), true),
    ("code", Some(obj([("state", str("code")), ("devices", Json::number(1.0)), ("untilText", str("14:05 前有效")), ("showing", Json::array([str("MacBook Pro")]))])), false),
    ("wrong", Some(obj([("state", str("wrong")), ("devices", Json::number(1.0)), ("error", str("安全码不正确"))])), false),
    ("checking", Some(obj([("state", str("checking")), ("devices", Json::number(1.0)), ("checkingText", str("请在显示安全码的设备上完成身份验证"))])), false),
  ]
  for entry in states {
    let (label, pair, expect_card) = entry
    let adb_sig = @signals.signal(make_adb(pair))
    let t = setting_tester(Vault, 320.0, platform=2, mode="settings-vault-own-outside", h=640.0, over=fn(base) {
      {
        ..base,
        topic_read: fn(name, params) {
          if name == "adbShare" {
            { value: Some(adb_sig.get()), error: None, version: 1 }
          } else {
            (base.topic_read)(name, params)
          }
        },
      }
    })
    t.set_font_scale(1.3)
    t.frame()
    t.run_for(@ui.move_most_ms)
    if expect_card {
      assert_true(t.find("Pixel 9 · youdid.wtf Android") is Some(_), msg="\{label}: missing Pixel 9 · youdid.wtf Android")
      assert_true(t.find("monoid 桌面版") is Some(_), msg="\{label}: long name truncated or missing")
      for drawn in t.words() {
        assert_false(drawn.0.contains("…") && drawn.0.contains("研发部门"), msg="\{label}: unexpected ellipsis in \{drawn.0}")
      }
    } else {
      assert_true(t.find("Pixel 9 · youdid.wtf Android") is None, msg="\{label}: approvers card should not show")
      assert_true(t.find("研发部门") is None, msg="\{label}: long approver should not show")
    }
    let faults = t.audit()
    assert_true(faults.is_empty(), msg="\{label} 320x640 @1.3: " + faults.join(" | "))
  }
}
