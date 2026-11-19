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
    ("settings-vault-own-outside", ["此设备尚未获批", "在你的受信任设备上批准这台设备后，即可在此使用密钥库。", "发送批准请求"], ["去安全设置"]),
    ("settings-vault-own-code", ["此设备尚未获批"], ["去安全设置", "发送批准请求"]),
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
