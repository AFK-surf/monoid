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
  // Clicking 申请授权 passes the specific vault id to vault.ask and reports personal vs workspace done wording.
  let calls : Array[(String, Json)] = []
  let t = setting_tester(Vault, 1100.0, platform=0, mode="settings-vault-no-key-code", over=fn(base) {
    {
      ..base,
      call: fn(name, params, done) {
        calls.push((name, params))
        (base.call)(name, params, done)
      },
    }
  })
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="申请授权")
  t.run_for(@ui.move_most_ms)
  let asked = calls.filter(fn(c) { c.0 == "vault.ask" })
  assert_eq(asked.length(), 1)
  assert_eq(asked[0].1, { "workspace": "ws1", "vault": "v1" })
  assert_eq(@sfbase.toast_words(), "已提交授权申请；也可在已有钥匙的设备「密钥库 › 设备」中手动授权")
  // Workspace no-key vault passes its vault id and notifies vault admins.
  let ws_calls : Array[(String, Json)] = []
  let ws_vaults : Json = obj([
    ("available", Json::boolean(true)),
    ("locked", Json::boolean(false)),
    ("canSign", Json::boolean(true)),
    ("setUp", Json::boolean(true)),
    ("thisDeviceCode", str("M5J-TK5")),
    ("vaults", Json::array([
      obj([
        ("id", str("v-ws")),
        ("name", str("Workspace 密钥库")),
        ("scope", str("workspace")),
        ("mine", Json::boolean(false)),
        ("manages", Json::boolean(false)),
        ("keyed", Json::boolean(false)),
        ("recoverable", Json::boolean(false)),
        ("items", Json::number(0.0)),
        ("devices", Json::number(1.0)),
      ]),
    ])),
    ("requests", Json::array([])),
    ("refused", Json::array([])),
  ])
  let t_ws = setting_tester(Vault, 1100.0, platform=0, mode="settings-vault-no-key-code", over=fn(base) {
    {
      ..base,
      topic_read: fn(name, params) {
        if name == "vaults" {
          { value: Some(ws_vaults), error: None, version: 1 }
        } else {
          (base.topic_read)(name, params)
        }
      },
      call: fn(name, params, done) {
        ws_calls.push((name, params))
        (base.call)(name, params, done)
      },
    }
  })
  t_ws.run_for(@ui.move_most_ms)
  t_ws.click(Button, label="申请授权")
  t_ws.run_for(@ui.move_most_ms)
  let ws_asked = ws_calls.filter(fn(c) { c.0 == "vault.ask" })
  assert_eq(ws_asked.length(), 1)
  assert_eq(ws_asked[0].1, { "workspace": "ws1", "vault": "v-ws" })
  assert_eq(@sfbase.toast_words(), "已提交授权申请；管理员也可在「密钥库 › 设备」中手动授权")
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

///|
fn vault_open_ok(value : String) -> Result[Json, Json] {
  Ok(
    obj([
      (
        "plain",
        obj([
          ("kind", str("token")),
          ("name", str("GitHub token")),
          ("fields", obj([("value", str(value))])),
          ("domains", []),
          ("notes", str("")),
        ]),
      ),
      (
        "shown",
        Json::array([
          obj([
            ("key", str("value")),
            ("label", str("值")),
            ("value", str(value)),
            ("secret", Json::boolean(true)),
            ("mono", Json::boolean(true)),
          ]),
        ]),
      ),
    ]),
  )
}

///|
/// Creates a Tester hosting a custom view tree over the settings fixture with `vault.open` calls captured in `pending`.
fn vault_isolation_tester(
  pending : Array[(Result[Json, Json]) -> Unit],
  w? : Double = 1100.0,
  h? : Double = 900.0,
  over? : (Source) -> Source = fn(s) { s },
  mount : (@view.View, Core) -> Unit,
) -> @ui.Tester {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let base_src = over(@sffixture.fixture("settings"))
  let src = {
    ..base_src,
    call: fn(name, params, done) {
      if name == "vault.open" {
        pending.push(done)
      } else {
        (base_src.call)(name, params, done)
      }
    },
  }
  let core = @sfbase.settings_core(src, rig_workspace)
  let t = @ui.Tester::new(
    @ui.old_views_here,
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      @sf.presented_nodes(root)
    },
    w~,
    h~,
    platform=0,
  )
  @ui.set_view_app(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      mount(root, core)
      @sf.presented_nodes(root)
    },
    around=fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() {
        @ui.old_views_here(c)
        @sf.presented(c)
      })
    },
  )
  t.draw()
  t
}

///|
test "PR-B0: two concurrent VaultItem instances isolate plaintext, opening spinner, and closing" {
  let pending : Array[(Result[Json, Json]) -> Unit] = []
  let show_a : @signals.Signal[Bool] = @signals.signal(true)
  let show_b : @signals.Signal[Bool] = @signals.signal(true)
  let t = vault_isolation_tester(pending, w=1200.0, fn(root, core) {
    let here = fn() { @settings.here_of(core, rig_workspace.id, rig_workspace.name) }
    let frame = fn() -> PageFrame { { back: None, top: 0.0, foot: 0.0, named: false } }
    root.row(Is(true)).grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    root.box(fn(left) {
      left.width(Is(Some(600.0))).height(Is(Some(900.0))) |> ignore
      left.show(fn() { show_a.get() }, fn(p) {
        p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        vault_item_node(p, core, here, "v1", "it1", on_back=fn() {  }, frame~, width=fn() { 600.0 })
      })
    })
    |> ignore
    root.box(fn(right) {
      right.width(Is(Some(600.0))).height(Is(Some(900.0))) |> ignore
      right.show(fn() { show_b.get() }, fn(p) {
        p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        vault_item_node(p, core, here, "v1", "it1", on_back=fn() {  }, frame~, width=fn() { 600.0 })
      })
    })
    |> ignore
  })
  // Both instances start masked with one "显示" button each
  let eyes = t.all(Button, label="显示")
  assert_eq(eyes.length(), 2)
  assert_true(t.find("ghp_inst_a") is None)
  assert_true(t.find("ghp_inst_b") is None)
  // Click eye in Instance A (left half, x < 600)
  let eye_a = eyes.iter().find_first(fn(n) { n.rect.0 < 600.0 }).unwrap()
  t.tap(eye_a.rect.0 + eye_a.rect.2 / 2.0, eye_a.rect.1 + eye_a.rect.3 / 2.0)
  t.draw()
  assert_eq(pending.length(), 1)
  // Instance A is spinning (no "显示" on left); Instance B still shows its "显示" button on right
  let eyes_during_a = t.all(Button, label="显示")
  assert_eq(eyes_during_a.length(), 1)
  assert_true(eyes_during_a[0].rect.0 >= 600.0, msg="Instance B must not spin while Instance A opens")
  // Complete Instance A open: plaintext appears ONLY in Instance A, never in Instance B
  pending[0](vault_open_ok("ghp_inst_a"))
  t.draw()
  let drawn_a = t.words().filter(fn(w) { w.0.contains("ghp_inst_a") })
  assert_true(drawn_a.length() > 0, msg="Instance A should show its plaintext")
  assert_true(drawn_a.iter().all(fn(w) { w.1 < 600.0 }), msg="Instance A plaintext must not leak into Instance B")
  assert_eq(t.all(Button, label="显示").length(), 1, msg="Instance B should remain masked")
  // Now open Instance B independently
  let eye_b = t.all(Button, label="显示")[0]
  t.tap(eye_b.rect.0 + eye_b.rect.2 / 2.0, eye_b.rect.1 + eye_b.rect.3 / 2.0)
  t.draw()
  assert_eq(pending.length(), 2)
  pending[1](vault_open_ok("ghp_inst_b"))
  t.draw()
  assert_true(t.find("ghp_inst_a") is Some(_))
  assert_true(t.find("ghp_inst_b") is Some(_))
  // Closing Instance A (and notifying settings.left) must NOT clear Instance B
  show_a.set(false)
  @settings.left(VaultItem("v1", "it1"))
  t.draw()
  assert_true(t.find("ghp_inst_a") is None, msg="Instance A plaintext should clear on close")
  assert_true(t.find("ghp_inst_b") is Some(_), msg="Closing Instance A must not clear Instance B")
}

///|
test "PR-B0: stack cover and return reuses page instance but invalidates pending_id, plaintext, and open editor dialog" {
  let pending : Array[(Result[Json, Json]) -> Unit] = []
  let covered : @signals.Signal[Bool] = @signals.signal(false)
  let built_count : Ref[Int] = Ref(0)
  let t = vault_isolation_tester(pending, w=1100.0, fn(root, core) {
    let here = fn() { @settings.here_of(core, rig_workspace.id, rig_workspace.name) }
    let frame = fn() -> PageFrame { { back: None, top: 0.0, foot: 0.0, named: false } }
    // Keeps the VaultItem page instance parked while covered (same instance resumed on return)
    root.each(
      at_once=true,
      fn() { if covered.get() { ["cover"] } else { ["vault"] } },
      fn(k) { k },
      keeps=fn() { if covered.get() { ["vault"] } else { [] } },
      fn(p, key) {
        p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        if key.untracked() == "vault" {
          built_count.val += 1
          vault_item_node(p, core, here, "v1", "it1", on_back=fn() {  }, frame~, active=fn() { !covered.get() }, width=fn() { 1100.0 })
        } else {
          @sf.page_note_node(p, fn() { "覆盖页" })
        }
      },
    )
  })
  assert_eq(built_count.val, 1)
  // Start vault.open before being covered
  t.click(Button, label="显示")
  t.draw()
  assert_eq(pending.length(), 1)
  // Cover the page in stack -> parks instance and invalidates pending_id
  covered.set(true)
  t.draw()
  assert_true(t.find("覆盖页") is Some(_))
  // Return to the SAME reused page instance
  covered.set(false)
  t.draw()
  assert_eq(built_count.val, 1, msg="VaultItem page instance should be reused on return")
  // Late pre-cover vault.open callback must be rejected even after returning to the same instance
  pending[0](vault_open_ok("ghp_stale_before_cover"))
  t.draw()
  assert_true(t.find("ghp_stale_before_cover") is None, msg="Pre-cover vault.open callback must be rejected after return")
  assert_true(t.query(Button, label="显示") is Some(_), msg="Field should remain masked after stale callback")
  // A fresh request after return works normally
  t.click(Button, label="显示")
  t.draw()
  assert_eq(pending.length(), 2)
  pending[1](vault_open_ok("ghp_fresh_after_return"))
  t.draw()
  assert_true(t.find("ghp_fresh_after_return") is Some(_))
  // Open editor dialog, then cover the page -> dialog closes and plaintext clears
  t.click(Button, label="编辑")
  t.draw()
  presented_in(t)
  assert_true(@sf.presenting(), msg="Editor dialog should be open")
  covered.set(true)
  t.draw()
  assert_false(@sf.presenting(), msg="Covering VaultItem must close its editor dialog")
  covered.set(false)
  t.draw()
  assert_true(t.find("ghp_fresh_after_return") is None, msg="Plaintext must be cleared after cover")
  assert_true(t.query(Button, label="显示") is Some(_), msg="Field visibility must reset after cover")
}

///|
test "PR-B0: leave and immediately reopen same item under same account rejects late vault.open without writing or clearing new instance" {
  let pending : Array[(Result[Json, Json]) -> Unit] = []
  let t = setting_tester(VaultItem("v1", "it1"), 1100.0, platform=0, over=fn(base) {
    {
      ..base,
      call: fn(name, params, done) {
        if name == "vault.open" {
          pending.push(done)
        } else {
          (base.call)(name, params, done)
        }
      },
    }
  })
  // Instance 1 starts vault.open
  t.click(Button, label="显示")
  t.draw()
  assert_eq(pending.length(), 1)
  // Leave stack and immediately reopen the same VaultItem("v1", "it1")
  app.nav.pop() |> ignore
  t.draw()
  app.nav.push(Setting(VaultItem("v1", "it1")))
  t.draw()
  // Sub-case A: late callback from Instance 1 arrives before Instance 2 requests open
  pending[0](vault_open_ok("ghp_from_first"))
  t.draw()
  assert_true(t.find("ghp_from_first") is None, msg="Late callback from previous instance must not write to reopened page")
  assert_true(t.query(Button, label="显示") is Some(_))
  // Sub-case B: Instance 2 starts vault.open, leaves, reopens as Instance 3 which also starts vault.open;
  // Instance 2's late callback must neither write to Instance 3 nor clear Instance 3's opening state
  t.click(Button, label="显示")
  t.draw()
  assert_eq(pending.length(), 2)
  app.nav.pop() |> ignore
  t.draw()
  app.nav.push(Setting(VaultItem("v1", "it1")))
  t.draw()
  t.click(Button, label="显示")
  t.draw()
  assert_eq(pending.length(), 3)
  assert_true(t.query(Button, label="显示") is None, msg="Instance 3 should be in opening state")
  // Instance 2's late callback arrives while Instance 3 is still opening
  pending[1](vault_open_ok("ghp_from_second_stale"))
  t.draw()
  assert_true(t.find("ghp_from_second_stale") is None, msg="Instance 2 callback must not write to Instance 3")
  assert_true(t.query(Button, label="显示") is None, msg="Instance 2 callback must not clear Instance 3 opening state")
  // Now Instance 3's own callback succeeds cleanly
  pending[2](vault_open_ok("ghp_from_third_fresh"))
  t.draw()
  assert_true(t.find("ghp_from_third_fresh") is Some(_), msg="Instance 3 own callback should succeed")
}

///|
test "PR-B0: account switch, workspace switch, and vault lock immediately clear plaintext, dialog, and reject late callbacks" {
  let pending : Array[(Result[Json, Json]) -> Unit] = []
  let account_sub : @signals.Signal[String] = @signals.signal("u1")
  let ws_id : @signals.Signal[String] = @signals.signal("ws1")
  let vault_open : @signals.Signal[Bool] = @signals.signal(true)
  let t = vault_isolation_tester(
    pending,
    w=1100.0,
    over=fn(base) {
      {
        ..base,
        topic_read: fn(name, params) {
          let read = (base.topic_read)(name, params)
          if name == "vaults" {
            let open_now = vault_open.get()
            match read.value {
              Some(Object(m)) => {
                let out = Map::from_iter(m.iter())
                let vs = items(read.value, "vaults").map(fn(v) {
                  match v {
                    Object(vm) => {
                      let vm2 = Map::from_iter(vm.iter())
                      vm2["open"] = Json::boolean(open_now)
                      Json::object(vm2)
                    }
                    other => other
                  }
                })
                out["vaults"] = Json::array(vs)
                { ..read, value: Some(Json::object(out)) }
              }
              _ => read
            }
          } else if name == "vaultItems" {
            let open_now = vault_open.get()
            match read.value {
              Some(Object(m)) => {
                let out = Map::from_iter(m.iter())
                out["open"] = Json::boolean(open_now)
                { ..read, value: Some(Json::object(out)) }
              }
              _ => read
            }
          } else {
            read
          }
        },
      }
    },
    fn(root, core) {
      let here = fn() -> @settings.Here {
        { workspace: ws_id.get(), name: "WS", sub: account_sub.get(), email: account_sub.get() + "@example.com", person: "User", picture: "" }
      }
      let frame = fn() -> PageFrame { { back: None, top: 0.0, foot: 0.0, named: false } }
      root.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      vault_item_node(root, core, here, "v1", "it1", on_back=fn() {  }, frame~, width=fn() { 1100.0 })
    },
  )
  // 1. Account switch clears plaintext and rejects late callback
  t.click(Button, label="显示")
  t.draw()
  pending[0](vault_open_ok("ghp_account_u1"))
  t.draw()
  assert_true(t.find("ghp_account_u1") is Some(_))
  account_sub.set("u2")
  t.draw()
  assert_true(t.find("ghp_account_u1") is None, msg="Account switch must immediately clear plaintext")
  assert_true(t.query(Button, label="显示") is Some(_))
  // Late callback across account switch is rejected
  t.click(Button, label="显示")
  t.draw()
  assert_eq(pending.length(), 2)
  account_sub.set("u3")
  t.draw()
  pending[1](vault_open_ok("ghp_account_u2_late"))
  t.draw()
  assert_true(t.find("ghp_account_u2_late") is None, msg="Late callback after account switch must be rejected")
  // 2. Workspace switch clears plaintext and rejects late callback
  t.click(Button, label="显示")
  t.draw()
  assert_eq(pending.length(), 3)
  pending[2](vault_open_ok("ghp_ws1"))
  t.draw()
  assert_true(t.find("ghp_ws1") is Some(_))
  ws_id.set("ws2")
  t.draw()
  assert_true(t.find("ghp_ws1") is None, msg="Workspace switch must immediately clear plaintext")
  t.click(Button, label="显示")
  t.draw()
  assert_eq(pending.length(), 4)
  ws_id.set("ws1")
  t.draw()
  pending[3](vault_open_ok("ghp_ws2_late"))
  t.draw()
  assert_true(t.find("ghp_ws2_late") is None, msg="Late callback after workspace switch must be rejected")
  // 3. Vault lock (vaults/vaultItems open: true -> false) clears plaintext, closes dialog, and rejects late callback
  t.click(Button, label="显示")
  t.draw()
  assert_eq(pending.length(), 5)
  pending[4](vault_open_ok("ghp_before_lock"))
  t.draw()
  assert_true(t.find("ghp_before_lock") is Some(_))
  t.click(Button, label="编辑")
  t.draw()
  presented_in(t)
  assert_true(@sf.presenting(), msg="Editor dialog should open before lock")
  vault_open.set(false)
  t.draw()
  assert_true(t.find("ghp_before_lock") is None, msg="Vault lock must immediately clear plaintext")
  assert_false(@sf.presenting(), msg="Vault lock must close open editor dialog")
  // Late callback arriving after vault lock must be rejected
  vault_open.set(true)
  t.draw()
  t.click(Button, label="显示")
  t.draw()
  assert_eq(pending.length(), 6)
  vault_open.set(false)
  t.draw()
  pending[5](vault_open_ok("ghp_after_lock_late"))
  t.draw()
  assert_true(t.find("ghp_after_lock_late") is None, msg="Late callback after vault lock must be rejected")
  // 4. Explicit vault_lock_bump rejects in-flight callback even before topic updates
  vault_open.set(true)
  t.draw()
  t.click(Button, label="显示")
  t.draw()
  assert_eq(pending.length(), 7)
  @settings.vault_lock_bump("ws1")
  t.draw()
  pending[6](vault_open_ok("ghp_after_explicit_lock_late"))
  t.draw()
  assert_true(t.find("ghp_after_explicit_lock_late") is None, msg="Late callback after explicit vault.lock must be rejected")
}

///|
test "PR-B0: explicit vault.lock clears all workspaces while single-vault lock clears only that vault" {
  let pending : Array[(Result[Json, Json]) -> Unit] = []
  let captured_core : Ref[Core?] = Ref(None)
  let t = vault_isolation_tester(pending, w=1200.0, fn(root, core) {
    captured_core.val = Some(core)
    let here_ws1 = fn() -> @settings.Here {
      { workspace: "ws1", name: "WS1", sub: "u1", email: "u1@example.com", person: "User", picture: "" }
    }
    let here_ws2 = fn() -> @settings.Here {
      { workspace: "ws2", name: "WS2", sub: "u1", email: "u1@example.com", person: "User", picture: "" }
    }
    let frame = fn() -> PageFrame { { back: None, top: 0.0, foot: 0.0, named: false } }
    root.row(Is(true)).grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    root.box(fn(left) {
      left.width(Is(Some(600.0))).height(Is(Some(900.0))) |> ignore
      vault_item_node(left, core, here_ws1, "v1", "it1", on_back=fn() {  }, frame~, width=fn() { 600.0 })
    })
    |> ignore
    root.box(fn(right) {
      right.width(Is(Some(600.0))).height(Is(Some(900.0))) |> ignore
      vault_item_node(right, core, here_ws2, "v1", "it1", on_back=fn() {  }, frame~, width=fn() { 600.0 })
    })
    |> ignore
  })
  let core = captured_core.val.unwrap()
  // Open both workspaces
  let eyes = t.all(Button, label="显示")
  assert_eq(eyes.length(), 2)
  let eye_ws1 = eyes.iter().find_first(fn(n) { n.rect.0 < 600.0 }).unwrap()
  let eye_ws2 = eyes.iter().find_first(fn(n) { n.rect.0 >= 600.0 }).unwrap()
  t.tap(eye_ws1.rect.0 + eye_ws1.rect.2 / 2.0, eye_ws1.rect.1 + eye_ws1.rect.3 / 2.0)
  t.draw()
  pending[0](vault_open_ok("ghp_ws1_open"))
  t.draw()
  t.tap(eye_ws2.rect.0 + eye_ws2.rect.2 / 2.0, eye_ws2.rect.1 + eye_ws2.rect.3 / 2.0)
  t.draw()
  pending[1](vault_open_ok("ghp_ws2_open"))
  t.draw()
  assert_true(t.find("ghp_ws1_open") is Some(_))
  assert_true(t.find("ghp_ws2_open") is Some(_))
  // Single-vault lock on (ws1, v1) clears ONLY ws1 and leaves ws2 intact
  @settings.vault_lock_bump("ws1", vault="v1")
  t.draw()
  assert_true(t.find("ghp_ws1_open") is None, msg="Single-vault lock must clear (ws1, v1)")
  assert_true(t.find("ghp_ws2_open") is Some(_), msg="Single-vault lock on ws1 must not clear ws2")
  // Re-open ws1, then trigger explicit vault.lock -> clears BOTH ws1 and ws2
  let eye_ws1_again = t.all(Button, label="显示")[0]
  t.tap(eye_ws1_again.rect.0 + eye_ws1_again.rect.2 / 2.0, eye_ws1_again.rect.1 + eye_ws1_again.rect.3 / 2.0)
  t.draw()
  pending[2](vault_open_ok("ghp_ws1_reopen"))
  t.draw()
  assert_true(t.find("ghp_ws1_reopen") is Some(_))
  @settings.vault_act(core, "ws1", "lock", [], "锁定")
  t.draw()
  assert_true(t.find("ghp_ws1_reopen") is None, msg="Explicit vault.lock must clear ws1")
  assert_true(t.find("ghp_ws2_open") is None, msg="Explicit vault.lock must clear ws2 across workspaces")
  // Late callbacks in both workspaces after explicit vault.lock are rejected
  let eyes2 = t.all(Button, label="显示")
  assert_eq(eyes2.length(), 2)
  for e in eyes2 {
    t.tap(e.rect.0 + e.rect.2 / 2.0, e.rect.1 + e.rect.3 / 2.0)
    t.draw()
  }
  assert_eq(pending.length(), 5)
  @settings.vault_act(core, "ws1", "lock", [], "锁定")
  t.draw()
  pending[3](vault_open_ok("ghp_ws1_late_after_all_lock"))
  pending[4](vault_open_ok("ghp_ws2_late_after_all_lock"))
  t.draw()
  assert_true(t.find("ghp_ws1_late_after_all_lock") is None)
  assert_true(t.find("ghp_ws2_late_after_all_lock") is None)
}

///|
test "PR-B0: real Nav cover and same-batch cover+return invalidate plaintext, late vault.open, and stale edit" {
  let pending : Array[(Result[Json, Json]) -> Unit] = []
  let built_count : Ref[Int] = Ref(0)
  let t = vault_isolation_tester(pending, w=1100.0, fn(root, core) {
    app.nav.push(Settings)
    app.nav.push(Setting(VaultItem("v1", "it1")))
    let vault_serial = @signals.untracked(fn() { app.nav.top_stay().0 })
    let here = fn() { @settings.here_of(core, rig_workspace.id, rig_workspace.name) }
    let frame = fn() -> PageFrame { { back: app.nav.under().map(@sfbase.back_label), top: 0.0, foot: 0.0, named: false } }
    // Host real app.nav entries with keeps so covered VaultItem stays mounted (not destroyed) like nav_view
    let top_serial = fn() { app.nav.top_stay().0 }
    let kept_serials = fn() {
      app.nav.top_stay() |> ignore
      let out : Array[Int] = []
      let top = top_serial()
      // keep the VaultItem entry while covered by a pushed page
      if app.nav.pages().length() > 2 && top != vault_serial {
        out.push(vault_serial)
      }
      out
    }
    root.each(
      at_once=true,
      fn() { [top_serial()] },
      fn(k) { k },
      keeps=kept_serials,
      fn(p, key) {
        let serial = key.untracked()
        p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        if serial == vault_serial {
          built_count.val += 1
          vault_item_node(
            p,
            core,
            here,
            "v1",
            "it1",
            on_back=core.pop,
            frame~,
            active=fn() { app.nav.top_stay().0 == serial },
            stay=fn() { app.nav.top_stay().1 },
            width=fn() { 1100.0 },
          )
        } else {
          @sf.page_note_node(p, fn() { "覆盖页 About" })
        }
      },
    )
  })
  assert_eq(built_count.val, 1)
  // 1. Real Nav push covers VaultItem without destroying it -> clears plaintext and rejects late callback
  t.click(Button, label="显示")
  t.draw()
  pending[0](vault_open_ok("ghp_nav_open"))
  t.draw()
  assert_true(t.find("ghp_nav_open") is Some(_))
  app.nav.push(Setting(About))
  t.draw()
  assert_true(t.find("覆盖页 About") is Some(_))
  app.nav.pop() |> ignore
  t.draw()
  assert_eq(built_count.val, 1, msg="VaultItem instance should be reused after Nav pop")
  assert_true(t.find("ghp_nav_open") is None, msg="Real Nav cover must clear plaintext")
  // In-flight vault.open across real Nav cover + pop is rejected
  t.click(Button, label="显示")
  t.draw()
  assert_eq(pending.length(), 2)
  app.nav.push(Setting(About))
  t.draw()
  app.nav.pop() |> ignore
  t.draw()
  pending[1](vault_open_ok("ghp_nav_late"))
  t.draw()
  assert_true(t.find("ghp_nav_late") is None, msg="Late callback across real Nav cover+pop must be rejected")
  // 2. Same-batch cover + return (no draw in between; active() stays true before & after, stay_id advances)
  t.click(Button, label="显示")
  t.draw()
  assert_eq(pending.length(), 3)
  @signals.start_batch()
  app.nav.push(Setting(About))
  app.nav.pop() |> ignore
  @signals.end_batch()
  // Even without drawing first, late callback must be rejected because stay_id changed
  pending[2](vault_open_ok("ghp_same_batch_late"))
  t.draw()
  assert_true(t.find("ghp_same_batch_late") is None, msg="Same-batch cover+return must reject stale vault.open via stay_id")
  // Same-batch cover + return must also prevent stale edit from opening editor with old plaintext
  t.click(Button, label="显示")
  t.draw()
  assert_eq(pending.length(), 4)
  pending[3](vault_open_ok("ghp_before_batch_edit"))
  t.draw()
  assert_true(t.find("ghp_before_batch_edit") is Some(_))
  @signals.start_batch()
  app.nav.push(Setting(About))
  app.nav.pop() |> ignore
  @signals.end_batch()
  t.click(Button, label="编辑")
  t.draw()
  assert_false(@sf.presenting(), msg="Same-batch cover+return must not open editor from stale plaintext")
  assert_eq(pending.length(), 5, msg="Edit after same-batch cover+return must issue a fresh vault.open")
}

///|
test "PR-B0: revoking open editor and about dialogs hides plaintext on first exit frame and blocks vault.putItem" {
  let pending : Array[(Result[Json, Json]) -> Unit] = []
  let puts : Array[Json] = []
  let vault_open : @signals.Signal[Bool] = @signals.signal(true)
  let t = vault_isolation_tester(
    pending,
    w=1100.0,
    over=fn(base) {
      {
        ..base,
        call: fn(name, params, done) {
          if name == "vault.putItem" {
            puts.push(params)
          } else {
            (base.call)(name, params, done)
          }
        },
        topic_read: fn(name, params) {
          let read = (base.topic_read)(name, params)
          if name == "vaultItems" {
            let open_now = vault_open.get()
            match read.value {
              Some(Object(m)) => {
                let out = Map::from_iter(m.iter())
                out["open"] = Json::boolean(open_now)
                { ..read, value: Some(Json::object(out)) }
              }
              _ => read
            }
          } else {
            read
          }
        },
      }
    },
    fn(root, core) {
      let here = fn() { @settings.here_of(core, rig_workspace.id, rig_workspace.name) }
      let frame = fn() -> PageFrame { { back: None, top: 0.0, foot: 0.0, named: false } }
      root.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      vault_item_node(root, core, here, "v1", "it1", on_back=fn() {  }, frame~, width=fn() { 1100.0 })
    },
  )
  let open_with_note = fn(value : String, note : String) -> Result[Json, Json] {
    Ok(
      obj([
        (
          "plain",
          obj([
            ("kind", str("token")),
            ("name", str("GitHub token")),
            ("fields", obj([("value", str(value))])),
            ("domains", []),
            ("notes", str(note)),
          ]),
        ),
        (
          "shown",
          Json::array([
            obj([
              ("key", str("value")),
              ("label", str("值")),
              ("value", str(value)),
              ("secret", Json::boolean(true)),
              ("mono", Json::boolean(true)),
            ]),
          ]),
        ),
      ]),
    )
  }
  // 1. About dialog: on lock, plaintext note disappears on the VERY FIRST exit frame (without running out animation)
  t.click(Button, label="显示")
  t.draw()
  pending[0](open_with_note("ghp_about_secret", "secret_note_42"))
  t.draw()
  t.click(Button, label="说明")
  t.draw()
  presented_in(t)
  assert_eq(t.get(TextField, label="说明").value, "secret_note_42", msg="About dialog should show note before lock")
  vault_open.set(false)
  t.draw()
  assert_true(t.find("secret_note_42") is None, msg="About dialog plaintext must be gone on first exit frame")
  assert_true(t.find("ghp_about_secret") is None, msg="Page plaintext must be gone on first exit frame")
  assert_true(t.query(TextField, label="说明") is None, msg="About dialog field must be hidden on first exit frame")
  assert_false(t.semantics().iter().any(fn(n) { n.value.contains("secret_note_42") }), msg="About dialog field buffer must be cleared on first exit frame")
  if t.query(Button, label="保存") is Some(_) {
    t.click(Button, label="保存")
    t.draw()
  }
  assert_eq(puts.length(), 0, msg="Revoked about dialog must never submit vault.putItem")
  // 2. Editor dialog: on lock, plaintext disappears on first exit frame and save is blocked
  vault_open.set(true)
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="显示")
  t.draw()
  pending[1](open_with_note("ghp_editor_secret", "editor_note_99"))
  t.draw()
  t.click(Button, label="编辑")
  t.draw()
  presented_in(t)
  assert_true(@sf.presenting(), msg="Editor dialog should be open")
  assert_true(t.query(TextField, label="值") is Some(_), msg="Editor secret value field should be present before lock")
  vault_open.set(false)
  t.draw()
  assert_true(t.find("ghp_editor_secret") is None, msg="Editor dialog plaintext must be gone on first exit frame")
  assert_true(t.query(TextField, label="值") is None, msg="Editor dialog body must be hidden on first exit frame")
  assert_false(t.semantics().iter().any(fn(n) { n.value.contains("ghp_editor_secret") }), msg="Editor field buffer must be cleared on first exit frame")
  if t.query(Button, label="保存") is Some(_) {
    t.click(Button, label="保存")
    t.draw()
  }
  assert_eq(puts.length(), 0, msg="Revoked editor dialog must never submit vault.putItem")
}

///|
test "PR-B0: revealed secret is not selectable via tree text selection while explicit copy button still copies" {
  let pending : Array[(Result[Json, Json]) -> Unit] = []
  let t = vault_isolation_tester(pending, w=1100.0, fn(root, core) {
    // Enable tree text selection on the page root (just like the narrow and wide app shells)
    @ui.words_picked(root)
    let here = fn() { @settings.here_of(core, rig_workspace.id, rig_workspace.name) }
    let frame = fn() -> PageFrame { { back: None, top: 0.0, foot: 0.0, named: false } }
    root.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    vault_item_node(root, core, here, "v1", "it1", on_back=fn() {  }, frame~, width=fn() { 1100.0 })
  })
  t.click(Button, label="显示")
  t.draw()
  pending[0](vault_open_ok("ghp_no_select_99"))
  t.draw()
  let (sx, sy) = t.find("ghp_no_select_99").unwrap()
  // Drag across the revealed secret value and press Cmd+C -> must NOT select or copy it
  t.drag(sx - 4.0, sy, sx + 140.0, sy)
  t.draw()
  t.key(@ui.key_of_char('c'), mods=@ui.mod_cmd)
  t.draw()
  assert_false(t.clipboard().contains("ghp_no_select_99"), msg="Revealed secret must not be selectable via tree text selection")
  // Explicit 30s copy button still copies as a secret
  t.click(Button, label="复制")
  t.draw()
  assert_eq(t.clipboard(), "ghp_no_select_99")
  assert_eq(t.clipboard_secret(), Some(@sf.secret_copied_life))
}

///|
test "PR-B0: invalidating or closing VaultItem does not steal keyboard focus from another input" {
  let pending : Array[(Result[Json, Json]) -> Unit] = []
  let show_vault : @signals.Signal[Bool] = @signals.signal(true)
  let other_field = @ui.Field::new()
  let t = vault_isolation_tester(pending, w=1200.0, fn(root, core) {
    let here = fn() { @settings.here_of(core, rig_workspace.id, rig_workspace.name) }
    let frame = fn() -> PageFrame { { back: None, top: 0.0, foot: 0.0, named: false } }
    root.row(Is(true)).grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    root.box(fn(left) {
      left.width(Is(Some(600.0))).height(Is(Some(900.0))) |> ignore
      left.show(fn() { show_vault.get() }, fn(p) {
        p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        vault_item_node(p, core, here, "v1", "it1", on_back=fn() {  }, frame~, width=fn() { 600.0 })
      })
    })
    |> ignore
    root.box(fn(right) {
      right.width(Is(Some(600.0))).height(Is(Some(900.0))) |> ignore
      @sf.input_node(right, other_field, label="其他输入框") |> ignore
    })
    |> ignore
  })
  // Open VaultItem plaintext
  t.click(Button, label="显示")
  t.draw()
  pending[0](vault_open_ok("ghp_focus_test"))
  t.draw()
  assert_true(t.find("ghp_focus_test") is Some(_))
  // Focus the sibling input and type "ab"
  t.click(TextField, label="其他输入框")
  t.draw()
  t.type_text("ab")
  t.draw()
  assert_eq(other_field.text(), "ab")
  // Lock VaultItem and then close it -> sibling input MUST keep keyboard focus
  @settings.vault_lock_bump("ws1", vault="v1")
  t.draw()
  assert_true(t.find("ghp_focus_test") is None)
  t.type_text("cd")
  t.draw()
  assert_eq(other_field.text(), "abcd", msg="Invalidating VaultItem must not steal focus from sibling input")
  show_vault.set(false)
  t.draw()
  t.type_text("ef")
  t.draw()
  assert_eq(other_field.text(), "abcdef", msg="Closing VaultItem must not steal focus from sibling input")
}

///|
test "PR-B0: unlisted secret private name and stacked delete confirm disappear on first exit frame without vault.deleteItem" {
  let pending : Array[(Result[Json, Json]) -> Unit] = []
  let deletes : Array[Json] = []
  let vault_open : @signals.Signal[Bool] = @signals.signal(true)
  let private_name = "unlisted_secret_name_77"
  let t = vault_isolation_tester(
    pending,
    w=1100.0,
    over=fn(base) {
      {
        ..base,
        call: fn(name, params, done) {
          if name == "vault.deleteItem" {
            deletes.push(params)
          } else {
            (base.call)(name, params, done)
          }
        },
        topic_read: fn(name, params) {
          let read = (base.topic_read)(name, params)
          if name == "vaultItems" {
            let open_now = vault_open.get()
            match read.value {
              Some(Object(m)) => {
                let out = Map::from_iter(m.iter())
                out["open"] = Json::boolean(open_now)
                { ..read, value: Some(Json::object(out)) }
              }
              _ => read
            }
          } else {
            read
          }
        },
      }
    },
    fn(root, core) {
      let here = fn() { @settings.here_of(core, rig_workspace.id, rig_workspace.name) }
      let frame = fn() -> PageFrame { { back: None, top: 0.0, foot: 0.0, named: false } }
      root.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      vault_item_node(root, core, here, "v1", "it1", on_back=fn() {  }, frame~, width=fn() { 1100.0 })
    },
  )
  let open_unlisted = fn() -> Result[Json, Json] {
    Ok(
      obj([
        (
          "plain",
          obj([
            ("kind", str("token")),
            ("name", str(private_name)),
            ("fields", obj([("value", str("ghp_unlisted_77"))])),
            ("domains", []),
            ("notes", str("")),
          ]),
        ),
        (
          "shown",
          Json::array([
            obj([
              ("key", str("value")),
              ("label", str("值")),
              ("value", str("ghp_unlisted_77")),
              ("secret", Json::boolean(true)),
              ("mono", Json::boolean(true)),
            ]),
          ]),
        ),
      ]),
    )
  }
  // 1. Open editor with private unlisted item name -> lock -> first exit frame has 0 private name in draw & semantics
  t.click(Button, label="显示")
  t.draw()
  pending[0](open_unlisted())
  t.draw()
  t.click(Button, label="编辑")
  t.draw()
  presented_in(t)
  assert_true(@sf.presenting())
  assert_true(t.find(private_name) is Some(_), msg="Editor dialog title should show private name before lock")
  vault_open.set(false)
  t.draw()
  assert_false(@sf.presenting(), msg="Editor presenter must drop immediately on lock")
  assert_true(t.find(private_name) is None, msg="Private name must disappear on first exit frame")
  assert_true(t.find("ghp_unlisted_77") is None, msg="Plaintext must disappear on first exit frame")
  assert_false(
    t.semantics().iter().any(fn(n) { n.label.contains(private_name) || n.value.contains(private_name) }),
    msg="Semantics labels and values must not retain private name on first exit frame",
  )
  // 2. Stack delete confirm on top of editor -> lock -> both confirm and editor drop immediately with 0 deleteItem
  vault_open.set(true)
  t.draw()
  t.click(Button, label="显示")
  t.draw()
  pending[1](open_unlisted())
  t.draw()
  t.click(Button, label="编辑")
  t.draw()
  presented_in(t)
  t.click(Button, label="删除")
  t.draw()
  presented_in(t)
  assert_true(t.find("删除「" + private_name + "」") is Some(_), msg="Delete confirm dialog should be stacked over editor")
  vault_open.set(false)
  t.draw()
  assert_false(@sf.presenting(), msg="Both delete confirm and editor must drop immediately on lock")
  assert_true(t.find(private_name) is None, msg="Confirm title private name must disappear on first exit frame")
  assert_true(t.find("ghp_unlisted_77") is None)
  assert_false(
    t.semantics().iter().any(fn(n) { n.label.contains(private_name) || n.value.contains(private_name) }),
    msg="Semantics must not retain private name after stacked confirm revocation",
  )
  assert_eq(deletes.length(), 0, msg="Revoking stacked delete confirm must never emit vault.deleteItem")
}

///|
test "PR-B0: deleteItem pops back to VaultItems regardless of whether vaultItems deletion arrives before or after RPC Ok" {
  for topic_first in [true, false] {
    let pending_open : Array[(Result[Json, Json]) -> Unit] = []
    let pending_del : Array[(Result[Json, Json]) -> Unit] = []
    let deleted : @signals.Signal[Bool] = @signals.signal(false)
    let t = setting_tester(VaultItems, 1100.0, platform=0, over=fn(base) {
      {
        ..base,
        call: fn(name, params, done) {
          if name == "vault.open" {
            pending_open.push(done)
          } else if name == "vault.deleteItem" {
            pending_del.push(done)
          } else {
            (base.call)(name, params, done)
          }
        },
        topic_read: fn(name, params) {
          let read = (base.topic_read)(name, params)
          if name == "vaultItems" && deleted.get() {
            match read.value {
              Some(Object(m)) => {
                let out = Map::from_iter(m.iter())
                out["items"] = Json::array(items(read.value, "items").filter(fn(x) { text(Some(x), "id") != "it1" }))
                { ..read, value: Some(Json::object(out)) }
              }
              _ => read
            }
          } else {
            read
          }
        },
      }
    })
    app.nav.push(Setting(VaultItem("v1", "it1")))
    t.draw()
    assert_true(app.nav.top() == Setting(VaultItem("v1", "it1")))
    // Open editor -> click 删除 -> confirm 删除
    t.click(Button, label="编辑")
    t.draw()
    assert_eq(pending_open.length(), 1)
    pending_open[0](vault_open_ok("ghp_del_race"))
    t.draw()
    presented_in(t)
    t.click(Button, label="删除")
    t.draw()
    presented_in(t)
    // Confirm dialog's "删除" button (the topmost one)
    let del_btns = t.all(Button, label="删除")
    let confirm_btn = del_btns[del_btns.length() - 1]
    t.tap(confirm_btn.rect.0 + confirm_btn.rect.2 / 2.0, confirm_btn.rect.1 + confirm_btn.rect.3 / 2.0)
    t.draw()
    assert_eq(pending_del.length(), 1)
    if topic_first {
      // Topic pushes item-deleted BEFORE deleteItem RPC Ok arrives
      deleted.set(true)
      t.draw()
      pending_del[0](Ok(Json::null()))
      t.draw()
    } else {
      // deleteItem RPC Ok arrives BEFORE topic pushes item-deleted
      pending_del[0](Ok(Json::null()))
      t.draw()
      deleted.set(true)
      t.draw()
    }
    assert_true(app.nav.top() == Setting(VaultItems), msg="topic_first=\{topic_first}: deleteItem must pop back to VaultItems")
  }
}

///|
test "PR-B0: real dual-window button lock from window A drops window B editor on frame 1 without leaking window A dialog" {
  let pending : Array[(Result[Json, Json]) -> Unit] = []
  let private_name = "win_b_secret_name_88"
  let core_ref : Ref[Core?] = Ref(None)
  let t = vault_isolation_tester(pending, w=1100.0, fn(root, core) {
    core_ref.val = Some(core)
    // Window A (wid = 0): real button triggering explicit vault.lock (runs inside Window A's outer signal batch)
    // plus a button to open an independent dialog in Window A.
    root.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    @sf.button_node(root, fn() { "窗口A锁定" }, fn() {
      @settings.vault_act(core, "ws1", "lock", [], "锁定")
    })
    |> ignore
    @sf.button_node(root, fn() { "窗口A开弹层" }, fn() {
      open_dialog_bare_nodes("窗口A独立弹层", fn(v, _) {
        @sf.words_node(v, fn() { "窗口A专属内容" }, fn() { @sf.card_body }) |> ignore
      })
    })
    |> ignore
  })
  let core = core_ref.val.unwrap()
  t.set_windows_in_process(true)
  // Register real secondary window tree for Window B hosting VaultItem + presented_nodes
  @ui.set_window_tree(fn(_wid, _what) {
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let here = fn() { @settings.here_of(core, rig_workspace.id, rig_workspace.name) }
      let frame = fn() -> PageFrame { { back: None, top: 0.0, foot: 0.0, named: false } }
      root.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      vault_item_node(root, core, here, "v1", "it1", on_back=fn() {  }, frame~, width=fn() { 1100.0 })
      @sf.presented_nodes(root)
    }
  })
  let wid_b = @ui.window_open_here("vault-b")
  assert_true(wid_b > 0, msg="Secondary window B should open")
  t.set_window_beside_size(wid_b, 1100.0, 900.0)
  t.draw()
  // Open an independent dialog in Window A so we can verify Window B never renders Window A's presenter stack
  t.click(Button, label="窗口A开弹层")
  t.draw()
  presented_in(t)
  assert_true(t.find("窗口A独立弹层") is Some(_), msg="Window A should show its own dialog")
  // In Window B: open VaultItem plaintext + editor dialog with private unlisted name
  let open_win_b = fn() -> Result[Json, Json] {
    Ok(
      obj([
        (
          "plain",
          obj([
            ("kind", str("token")),
            ("name", str(private_name)),
            ("fields", obj([("value", str("ghp_win_b_88"))])),
            ("domains", []),
            ("notes", str("win_b_note_88")),
          ]),
        ),
        (
          "shown",
          Json::array([
            obj([
              ("key", str("value")),
              ("label", str("值")),
              ("value", str("ghp_win_b_88")),
              ("secret", Json::boolean(true)),
              ("mono", Json::boolean(true)),
            ]),
          ]),
        ),
      ]),
    )
  }
  t.in_window(wid_b, fn() {
    match t.query(Button, label="显示") {
      Some(btn) => t.tap(btn.rect.0 + btn.rect.2 / 2.0, btn.rect.1 + btn.rect.3 / 2.0)
      None => ()
    }
  })
  t.draw()
  assert_eq(pending.length(), 1)
  pending[0](open_win_b())
  t.draw()
  t.in_window(wid_b, fn() {
    match t.query(Button, label="编辑") {
      Some(btn) => t.tap(btn.rect.0 + btn.rect.2 / 2.0, btn.rect.1 + btn.rect.3 / 2.0)
      None => ()
    }
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  let b_before_open : Ref[Bool] = Ref(false)
  let b_before_name : Ref[Bool] = Ref(false)
  t.in_window(wid_b, fn() {
    b_before_open.val = @sf.presenting()
    b_before_name.val = t.find(private_name) is Some(_)
  })
  assert_true(b_before_open.val && b_before_name.val, msg="Window B should display editor and private name before lock")
  // Trigger explicit vault.lock via a REAL button click in Window A (runs inside Window A's outer signal batch!)
  // Close Window A's modal dialog only after testing? No — click directly or trigger lock while Window A's dialog is up:
  // Put lock button inside Window A's dialog or close-independent: here Window A's dialog is modal, so click a lock
  // button inside Window A's dialog, or trigger via a real button press before opening? Wait: let's click Window A's
  // dialog? No, Window A's dialog covers root buttons, so let's close Window A's dialog? No! Even better: test BOTH:
  // click "窗口A锁定" directly inside Window A's dialog so Window A's dialog IS open during the real button batch!
  @sf.close_presented()
  t.run_for(@ui.move_most_ms)
  open_dialog_nodes(
    "窗口A独立弹层",
    fn(v, _) { @sf.words_node(v, fn() { "窗口A专属内容" }, fn() { @sf.card_body }) |> ignore },
    fn(v, _) {
      @sf.button_node(v, fn() { "在窗口A中锁定" }, fn() {
        @settings.vault_act(core, "ws1", "lock", [], "锁定")
      })
      |> ignore
    },
  )
  t.draw()
  presented_in(t)
  assert_true(t.find("窗口A独立弹层") is Some(_))
  // Real button click in Window A inside Window A's outer @signals.start_batch!
  t.click(Button, label="在窗口A中锁定")
  t.draw()
  // Window A STILL shows its own independent dialog
  assert_true(t.find("窗口A独立弹层") is Some(_), msg="Window A must keep its own independent dialog")
  // Window B's VERY FIRST frame after Window A's click: 0 private name, 0 plaintext, 0 Window A dialog leakage!
  let b_after_presenting : Ref[Bool] = Ref(true)
  let b_after_drawn : Ref[Bool] = Ref(true)
  let b_after_name : Ref[Bool] = Ref(true)
  let b_after_secret : Ref[Bool] = Ref(true)
  let b_after_sem_leak : Ref[Bool] = Ref(true)
  let b_after_win_a_leak : Ref[Bool] = Ref(true)
  t.in_window(wid_b, fn() {
    b_after_presenting.val = @sf.presenting()
    b_after_drawn.val = @sf.presented_drawn()
    b_after_name.val = t.find(private_name) is Some(_)
    b_after_secret.val = t.find("ghp_win_b_88") is Some(_)
    b_after_sem_leak.val = t.semantics().iter().any(fn(n) {
      n.label.contains(private_name) || n.value.contains(private_name) || n.value.contains("ghp_win_b_88")
    })
    b_after_win_a_leak.val = t.find("窗口A独立弹层") is Some(_) || t.find("窗口A专属内容") is Some(_)
  })
  assert_false(b_after_presenting.val, msg="Window B editor must be dropped immediately by Window A click")
  assert_false(b_after_drawn.val, msg="Window B must have zero drawn presenters")
  assert_false(b_after_name.val, msg="Window B private name must be gone on first frame")
  assert_false(b_after_secret.val, msg="Window B plaintext must be gone on first frame")
  assert_false(b_after_sem_leak.val, msg="Window B semantics must not retain private name or plaintext")
  assert_false(b_after_win_a_leak.val, msg="Window B must NEVER render Window A's presenter stack")
  // Subsequent reopen in Window B stays strictly in Window B and does not leak to Window A
  t.in_window(wid_b, fn() {
    open_dialog_bare_nodes("窗口B新弹层", fn(v, _) {
      @sf.words_node(v, fn() { "窗口B新内容" }, fn() { @sf.card_body }) |> ignore
    })
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("窗口A独立弹层") is Some(_), msg="Window A keeps its own dialog")
  assert_true(t.find("窗口B新弹层") is None, msg="Window B's new dialog must not appear in Window A")
  let b_reopen_ok : Ref[Bool] = Ref(false)
  let b_reopen_no_a : Ref[Bool] = Ref(false)
  t.in_window(wid_b, fn() {
    b_reopen_ok.val = t.find("窗口B新弹层") is Some(_)
    b_reopen_no_a.val = t.find("窗口A独立弹层") is None
  })
  assert_true(b_reopen_ok.val, msg="Window B should display its newly opened dialog")
  assert_true(b_reopen_no_a.val, msg="Window B must still not display Window A's dialog")
}

///|
test "PR-B0: lock during normal-close pop_out_ms hard-drops private title on frame 1 and blocks late file pick" {
  let pending : Array[(Result[Json, Json]) -> Unit] = []
  let vault_open : @signals.Signal[Bool] = @signals.signal(true)
  let private_name = "绝密证书-退场锁库"
  let t = vault_isolation_tester(
    pending,
    w=1100.0,
    over=fn(base) {
      {
        ..base,
        topic_read: fn(name, params) {
          let read = (base.topic_read)(name, params)
          if name == "vaultItems" {
            let open_now = vault_open.get()
            match read.value {
              Some(Object(m)) => {
                let out = Map::from_iter(m.iter())
                out["open"] = Json::boolean(open_now)
                { ..read, value: Some(Json::object(out)) }
              }
              _ => read
            }
          } else {
            read
          }
        },
      }
    },
    fn(root, core) {
      let here = fn() { @settings.here_of(core, rig_workspace.id, rig_workspace.name) }
      let frame = fn() -> PageFrame { { back: None, top: 0.0, foot: 0.0, named: false } }
      root.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      vault_item_node(root, core, here, "v1", "it1", on_back=fn() {  }, frame~, width=fn() { 1100.0 })
    },
  )
  let open_file = fn() -> Result[Json, Json] {
    Ok(
      obj([
        (
          "plain",
          obj([
            ("kind", str("file")),
            ("name", str(private_name)),
            ("fields", obj([("content", str("T1JJR19TRUNSRVRfQ09OVEVOVA==")), ("filename", str("orig-secret.pem"))])),
            ("domains", []),
            ("notes", str("file_note_99")),
          ]),
        ),
        (
          "shown",
          Json::array([
            obj([
              ("key", str("content")),
              ("label", str("文件")),
              ("value", str("orig-secret.pem")),
              ("secret", Json::boolean(true)),
              ("mono", Json::boolean(true)),
            ]),
          ]),
        ),
      ]),
    )
  }
  // Open item and open editor dialog
  t.click(Button, label="显示")
  t.draw()
  assert_eq(pending.length(), 1)
  pending[0](open_file())
  t.draw()
  t.click(Button, label="编辑")
  t.draw()
  presented_in(t)
  assert_true(@sf.presenting(), msg="editor dialog should be open")
  assert_true(t.find(private_name) is Some(_), msg="editor title should display private name before close")
  // 1. Active cancel button path: start manual file pick -> click Cancel -> late file pick must NOT write
  t.picks_by_hand()
  t.picks([("late-cancel.pem", b"LATE_CANCEL_BYTES")])
  t.click(Button, label=@sf.t("web-pages.vault.editor.pickFile"))
  t.draw()
  t.click(Button, label=@sf.t("common.cancel"))
  t.draw()
  assert_true(@sf.presented_drawn(), msg="dialog should still be drawing during cancel pop_out_ms exit animation")
  t.pick_answer(1)
  t.draw()
  assert_true(t.find("late-cancel.pem") is None, msg="late file pick must not write after clicking footer Cancel")
  t.run_for(@ui.move_most_ms)
  assert_false(@sf.presented_drawn(), msg="cancel exit animation should finish")
  // 2. Reopen editor -> Escape exit path + late file pick + mid-exit vault lock
  t.click(Button, label="编辑")
  t.draw()
  presented_in(t)
  assert_true(@sf.presenting(), msg="editor dialog should reopen")
  assert_true(t.find(private_name) is Some(_), msg="editor title should display private name before Escape")
  t.picks([("late-cert.pem", b"LATE_SECRET_BYTES")])
  t.click(Button, label=@sf.t("web-pages.vault.editor.pickFile"))
  t.draw()
  // Trigger normal close via Escape -> enters pop_out_ms exit animation
  t.key(@ui.key_escape)
  t.draw()
  assert_true(@sf.presented_drawn(), msg="dialog should still be drawing during pop_out_ms exit animation")
  // Late file pick arrives during exit animation: on_gone already revoked & cleared it, so it must NOT be written
  t.pick_answer(2)
  t.draw()
  assert_true(t.find("late-cert.pem") is None, msg="late file pick must not write into closing editor")
  // Lock vault mid-exit-animation: must hard-drop the closing overlay on the very next frame!
  vault_open.set(false)
  t.draw()
  assert_false(@sf.presenting(), msg="presenting must be false after lock during pop_out_ms")
  assert_false(@sf.presented_drawn(), msg="closing overlay must be hard-dropped immediately on lock during pop_out_ms")
  assert_true(t.find(private_name) is None, msg="private name must not appear on first frame after lock")
  assert_true(t.find("orig-secret.pem") is None, msg="plaintext filename must not appear on first frame after lock")
  assert_true(t.find("late-cert.pem") is None, msg="late picked file must not appear after lock")
  let sem_leak = t.semantics().iter().any(fn(n) {
    n.label.contains(private_name) ||
    n.value.contains(private_name) ||
    n.label.contains("orig-secret.pem") ||
    n.value.contains("orig-secret.pem") ||
    n.label.contains("late-cert.pem") ||
    n.value.contains("late-cert.pem")
  })
  assert_false(sem_leak, msg="semantics must have zero private name or plaintext on frame 1 after lock")
}
