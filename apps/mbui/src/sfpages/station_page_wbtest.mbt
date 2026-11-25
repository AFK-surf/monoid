// A station's page in its three parts (station_node.mbt, resources.mbt) alone over the
// settings' fixture: Willow (ws1/st1), online. At a phone's width with a finger, in a box tall enough for all of a
// part.

///|
/// Station `address`'s page, its part `part` (overview 概览, processes 进程, settings 设置, machine 软件与设备) shown;
/// `w` wide, pointed at as `platform` says (a phone's finger, else 0 a Mac's mouse).
fn station_tester(address : String, part? : String = "overview", w? : Double = 390.0, platform? : Int = 2) -> @ui.Tester {
  let t = setting_tester(Station(address), w, platform~, h=2400.0, ready=fn() { @settings.station_parts[address] = part })
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// A part of a station's page made once (`make`) alone in a window `w` wide and `h` high, pointed at as `platform`
/// says, laid out as a page that wide is, the presenters and the old views it hosts round it (setting_tester's).
fn station_part_tester(make : (@view.View) -> Unit, w~ : Double, h~ : Double, platform~ : Int) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_) {  }, w~, h~, platform~)
  @ui.set_view_app(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.box(fn(p) {
        p.grow(Is(1.0)) |> ignore
        @sf.look_lent(p, @sf.look_for(w))
        make(p)
      })
      |> ignore
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
test "who is on a screen: each view's device and mode; a member lets one go or all, an agent's and a reader's not" {
  for (w, platform) in page_cases {
    @sfbase.reset()
    reset()
    @settings.reset()
    @sffixture.fixture_reset()
    @sf.presenters_reset()
    @sf.set_words(@sfbase.fill)
    let calls : Array[(String, Json)] = []
    let base = @sffixture.fixture("settings")
    let src : Source = {
      ..base,
      call: fn(name, params, done) {
        if name.has_prefix("screen.") { calls.push((name, params)) }
        done(Ok(Json::null()))
      },
    }
    let view = fn(id : String, name : String, control : Bool, more : Map[String, Json]) -> Json {
      let m : Map[String, Json] = {
        "id": Json::string(id),
        "name": Json::string(name),
        "device": Json::string("still.fail 桌面版 · 书房"),
        "ago": Json::string("13 小时前"),
        "control": Json::boolean(control),
      }
      more.each(fn(k, v) { m[k] = v })
      Json::object(m)
    }
    let may : Map[String, Json] = { "may": Json::boolean(true) }
    let screen : Json = {
      "id": Json::string("desktop"),
      "views": Json::array([
        view("v1", "Willow", true, may),
        view("v2", "Bob", false, may),
        view("v3", "Agent「部署」", true, { "agent": Json::boolean(true) }),
      ]),
    }
    let core = @sfbase.settings_core(src, rig_workspace)
    let t = station_part_tester(fn(p) {
      screen_views_node(p, core, fn() { @settings.here_of(core, rig_workspace.id, rig_workspace.name) }, "ws1/st1", fn() {
        Some(screen)
      })
    }, w~, h=500.0, platform~)
    assert_true(t.find("still.fail 桌面版 · 书房 · 控制中 · 13 小时前") is Some(_), msg="\{w} platform \{platform}")
    assert_true(t.find("still.fail 桌面版 · 书房 · 只看 · 13 小时前") is Some(_))
    // 转为只看 for the one that drives; 断开 for both people's; the agent's has neither
    let said = fn(word : String) { t.words().filter(fn(w) { w.0 == word }).length() }
    assert_eq(said("转为只看"), 1)
    assert_eq(said("断开"), 2)
    t.click(Button, label="转为只看")
    t.click(Button, label="全部断开")
    t.draw()
    assert_eq(calls.map(fn(c) { c.0 }), ["screen.watchOnly", "screen.endViews"])
    assert_eq(text(Some(calls[0].1), "view"), "v1")
    assert_eq(text(Some(calls[0].1), "screen"), "desktop")
    assert_eq(text(Some(calls[0].1), "station"), "ws1/st1")
  }
}

///|
test "a failed software update shows its reason without a hover" {
  for (w, platform) in page_cases {
    @sfbase.reset()
    reset()
    @settings.reset()
    @sffixture.fixture_reset()
    @sf.presenters_reset()
    @sf.set_words(@sfbase.fill)
    let src = @sffixture.fixture("settings")
    let reason = "文件可能已加密或损坏，请检查文件加密软件"
    let update : Json = {
      "id": "station", "name": "Station", "installed": true, "updatable": true,
      "state": "failed", "shownText": "0.1.6814", "failedText": "更新失败", "message": Json::string(reason),
    }
    let core = @sfbase.settings_core(src, rig_workspace)
    let t = station_part_tester(fn(p) {
      software_row_node(p, core, "ws1/st1", fn() { Some(update) }, true, fn() { false }, fn() { false }, fn() { true }, @sf.TipLayer::new(fn() { None }))
    }, w~, h=300.0, platform~)
    assert_true(t.find(reason) is Some(_), msg="\{w} platform \{platform}")
    assert_true(t.query(Button, label="重试") is Some(_))
  }
}

///|
test "a station's update said beside its name keeps clear of the name" {
  for (w, platform) in page_cases {
    @sfbase.reset()
    reset()
    @settings.reset()
    @sffixture.fixture_reset()
    @sf.presenters_reset()
    @sf.set_words(@sfbase.fill)
    let src = @sffixture.fixture("settings")
    let update : Json = {
      "id": "station", "name": "Station", "installed": true, "updatable": true, "state": "idle",
      "shownText": "0.1.8100", "done": "已更新到 0.1.8100，agent 未中断", "channel": "beta", "auto": true,
    }
    let core = @sfbase.settings_core(src, rig_workspace)
    let t = station_part_tester(fn(p) {
      software_row_node(p, core, "ws1/st1", fn() { Some(update) }, true, fn() { false }, fn() { true }, fn() { true }, @sf.TipLayer::new(fn() { None }))
    }, w~, h=300.0, platform~)
    // (the phone in the report had its words bigger: the system's setting, 1.3)
    for scale in [1.0, 1.3] {
      t.set_font_scale(scale)
      t.draw()
      let at = "\{w} platform \{platform} words at \{scale}"
      let words = t.words()
      let name = words.search_by(fn(x) { x.0 == "Station" })
      let said = words.search_by(fn(x) { x.0.contains("已更新到 0.1.8100") })
      guard name is Some(n) && said is Some(d) else { fail("not drawn: \{at}") }
      let (_, nx, ny, nw, nh, _) = words[n]
      let (_, dx, dy, dw, dh, _) = words[d]
      let apart = dx >= nx + nw || nx >= dx + dw || dy >= ny + nh || ny >= dy + dh
      assert_true(apart, msg="\{at}: Station at (\{nx}, \{ny}, \{nw}, \{nh}), what it says at (\{dx}, \{dy}, \{dw}, \{dh})")
      assert_eq(t.squeeze_faults(), [], msg=at)
    }
  }
}

///|
test "an incomplete Codex offers its manager an explicit npm repair" {
  for (w, platform) in page_cases {
    @sfbase.reset()
    reset()
    @settings.reset()
    @sffixture.fixture_reset()
    @sf.presenters_reset()
    @sf.set_words(@sfbase.fill)
    let calls : Array[Json] = []
    let base = @sffixture.fixture("settings")
    let src : Source = {
      ..base,
      call: fn(name, params, done) {
        if name == "software.update" { calls.push(params) }
        done(Ok(Json::null()))
      },
    }
    let codex : Json = {
      "id": Json::string("codex"),
      "name": Json::string("Codex"),
      "installed": Json::boolean(true),
      "repairable": Json::boolean(true),
      "state": Json::string("idle"),
      "shownText": Json::string("0.166.0"),
      "note": Json::string("Codex 缺少执行组件"),
    }
    let core = @sfbase.settings_core(src, rig_workspace)
    let t = station_part_tester(fn(p) {
      software_row_node(p, core, "ws1/st1", fn() { Some(codex) }, true, fn() { false }, fn() { false }, fn() { true }, @sf.TipLayer::new(fn() { None }))
    }, w~, h=300.0, platform~)
    assert_true(t.query(Button, label="用 npm 修复") is Some(_), msg="\{w} platform \{platform}")
    t.click(Button, label="用 npm 修复")
    t.frame()
    assert_eq(calls.length(), 1)
    assert_eq(text(Some(calls[0]), "id"), "codex")
    assert_true(flag(Some(calls[0]), "repair"))
  }
}

///|
test "a station's page in three parts: 概览 what runs on it, 进程 what still.fail uses, 设置 its software and settings" {
  let t = station_tester("ws1/st1")
  // 概览: what runs on it, its screens and files
  assert_true(t.find("概览") is Some(_))
  assert_true(t.find("屏幕、浏览器与终端") is Some(_), msg=t.words().map(fn(w) { w.0 }).join("|"))
  assert_true(t.find("文件") is Some(_))
  assert_true(t.find("设备信息") is None)
  // what the machine is, in the 资源 card over its dials: the cores, the architecture and the hostname the head's
  // line does not say
  let (_, made_y) = t.find("Apple M1 Pro · 10 核 · arm64 · macOS 26.2 · willow").unwrap()
  let (_, dials_y) = t.find("CPU 空闲率").unwrap()
  let (_, title_y) = t.find("资源").unwrap()
  assert_true(title_y < made_y && made_y < dials_y, msg="under 资源 and over its dials")
  // 进程: what still.fail uses of the machine
  @settings.station_parts["ws1/st1"] = "processes"
  t.draw()
  assert_true(t.find("修一下登录") is Some(_), msg="its processes")
  assert_true(t.find("文件") is None, msg="the overview gone")
  // 设置: its software, what macOS lets it do, its runtime settings
  @settings.station_parts["ws1/st1"] = "settings"
  t.draw()
  assert_true(t.find("软件与更新") is Some(_))
  assert_true(t.find("权限") is Some(_), msg="its grants")
  assert_true(t.find("Agent 环境变量") is Some(_), msg="its variables")
}

///|
test "a new station's backup to restore is a row of its 设置, 恢复到这台 its one button" {
  for (w, platform) in page_cases {
    let at = "\{w} platform \{platform}"
    // legacy station without backup field: quiet backup status stays hidden
    let legacy = setting_tester(Station("ws1/st1"), w, platform~, mode="settings-station-copies-alone", h=2400.0)
    legacy.run_for(@ui.move_most_ms)
    assert_true(legacy.find("再加一台 station 就会自动备份") is None, msg="quiet legacy backup status not shown: \{at}")
    assert_true(legacy.find("恢复到这台") is None, msg="nothing to press: \{at}")
    // station with backup settings (no restore offers): quiet backup status stays in the dedicated 备份 tab, not Station 设置
    let t = setting_tester(Station("ws1/st1"), w, platform~, mode="settings-station-copies", h=2400.0)
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("已备份到 Cedar 和 Aspen · 2 分钟前") is None, msg="quiet backup status moved to 备份 tab: \{at}")
    assert_true(t.find("允许替其他 Station 存备份") is None, msg="config not shown in Station 设置: \{at}")
    // a new station: the backup of a station no longer there in 设置, 恢复到这台 its one button
    let r = setting_tester(Station("ws1/st1"), w, platform~, mode="settings-station-restore-offer", h=2400.0)
    r.run_for(@ui.move_most_ms)
    assert_true(r.find("Old Mac 的 128 个聊天") is Some(_), msg="what it would restore: \{at}")
    assert_true(r.find("恢复到这台") is Some(_), msg="its button: \{at}")
    let (_, vy) = r.find("Agent 环境变量").unwrap()
    let (_, by) = r.find("Old Mac 的 128 个聊天").unwrap()
    assert_true(vy < by, msg="after its settings: \{at}")
    let pairs = r.corner_pairs().filter(fn(p) { p.contains("恢复到这台") })
    assert_true(pairs.length() > 0, msg="the button counted in the card's corner: \{at}")
    let faults = r.corner_faults().filter(fn(f) { f.contains("恢复到这台") })
    assert_true(faults.length() == 0, msg="concentric with the card's corner: \{at} \{Repr(faults)}")
    @settings.station_parts["ws1/st1"] = "overview"
    r.draw()
    assert_true(r.find("恢复到这台") is None, msg="not on the overview: \{at}")
    assert_true(r.find("Old Mac 的 128 个聊天") is None, msg="not on the overview: \{at}")
  }
}

///|
test "backup tab and per-station backup page: sidebar row, unified apply with shared generated key, per-station flat config, S3 form, restore from S3, offline/non-admin read-only, audit clean" {
  // 1. Settings list has 备份 right between 归档 and 用量
  let nav = setting_tester(Home, 390.0, platform=2, h=1800.0)
  nav.run_for(@ui.move_most_ms)
  let arch_y = nav.find("归档").unwrap().1
  let back_y = nav.find("备份").unwrap().1
  let usage_y = nav.find("用量").unwrap().1
  assert_true(arch_y < back_y && back_y < usage_y, msg="备份 between 归档 and 用量: \{arch_y} < \{back_y} < \{usage_y}")
  assert_eq(nav.audit(), [], msg="audit settings home")
  // 2. Top-level Backup tab: unified settings + sequential multi-station apply sharing generatedKeys + station row navigation
  for (w, platform) in [(390.0, 2), (1280.0, 0)] {
    let at = "\{w} platform \{platform}"
    let calls : Array[(String, Json)] = []
    let t = setting_tester(Backup, w, platform~, mode="settings-backup", h=2600.0, over=fn(s) {
      {
        ..s,
        call: fn(name, params, done) {
          if name == "copies.setSettings" {
            calls.push((name, params))
            // First station generates an encryption key + id for the new S3 target when s3 is sent
            if calls.length() == 1 && field(Some(params), "s3") is Some(Array(_)) {
              done(
                Ok(
                  @settings.obj([
                    (
                      "generatedKeys",
                      @settings.obj([("r2abc123", Json::string("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))]),
                    ),
                  ]),
                ),
              )
            } else {
              done(Ok(@settings.obj([])))
            }
            return
          }
          (s.call)(name, params, done)
        },
      }
    })
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("统一设置") is Some(_), msg="unified heading: \{at}")
    assert_true(t.find("各 Station") is Some(_), msg="stations heading: \{at}")
    assert_true(t.find("应用到全部在线 Station") is Some(_), msg="apply button: \{at}")
    assert_true(t.find("Willow") is Some(_), msg="station Willow: \{at}")
    assert_true(t.find("Maple") is Some(_), msg="station Maple: \{at}")
    assert_true(t.find("手动互备：Cedar · Cloudflare R2 · 接收互备") is Some(_), msg="Willow settingsSummary: \{at}")
    assert_true(t.find("自动互备（2 台） · 接收互备") is Some(_), msg="Maple settingsSummary: \{at}")
    assert_eq(t.audit(), [], msg="audit backup tab \{at}: \{Repr(t.audit())}")
    assert_eq(t.squeeze_faults(), [], msg="squeeze backup tab \{at}: \{Repr(t.squeeze_faults())}")
    // Bug A: clicking 应用到全部在线 Station without touching S3 must NOT send `s3` field
    t.click(Button, label="应用到全部在线 Station")
    t.run_for(@ui.move_most_ms)
    assert_eq(calls.length(), 2, msg="two online stations updated (mode only): \{at}")
    assert_eq(text(Some(calls[0].1), "station"), "ws1/st1", msg="first station: \{at}")
    assert_eq(text(Some(calls[1].1), "station"), "ws1/st2", msg="second station: \{at}")
    assert_true(field(Some(calls[0].1), "s3") is None, msg="no s3 sent when untouched (st1): \{at}")
    assert_true(field(Some(calls[1].1), "s3") is None, msg="no s3 sent when untouched (st2): \{at}")
    // Bug B: adding a new R2 target marks s3 dirty and propagates BOTH generated id and encryptionKey from first succeeding station to rest
    calls.clear()
    t.tap_text("添加")
    t.run_for(@ui.move_most_ms)
    t.click(TextField, label="名称")
    t.type_text("R2 Extra")
    t.click(TextField, label="Bucket")
    t.type_text("extra-bkt")
    t.click(TextField, label="Endpoint URL")
    t.type_text("https://extra.r2.cloudflarestorage.com")
    t.click(TextField, label="Access Key ID")
    t.type_text("AKEXTRA")
    t.click(TextField, label="Secret Access Key")
    t.type_text("SKEXTRA")
    t.run_for(@ui.move_most_ms)
    t.click(Button, label="保存")
    t.run_for(@ui.move_most_ms)
    t.click(Button, label="应用到全部在线 Station")
    t.run_for(@ui.move_most_ms)
    assert_eq(calls.length(), 2, msg="two online stations updated (with new s3): \{at}")
    let second_s3 = items(Some(calls[1].1), "s3")
    assert_eq(second_s3.length(), 2, msg="second station s3 count: \{at}")
    let propagated = second_s3.iter().find_first(fn(x) { text(Some(x), "name") == "R2 Extra" })
    assert_true(propagated is Some(_), msg="new target present on second station: \{at}")
    assert_eq(text(propagated, "id"), "r2abc123", msg="generated id propagated to second station: \{at}")
    assert_eq(
      text(propagated, "encryptionKey"),
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      msg="shared generated key propagated to second station: \{at}",
    )
    // Recovery key dialog popped once
    assert_true(t.find("保存端到端加密恢复密钥") is Some(_), msg="generated key dialog: \{at}")
    t.click(Button, label="我已保存")
    t.run_for(@ui.move_most_ms)
    // Clicking a station row navigates to StationBackup(address)
    let willow_rows = t.words().filter(fn(x) { x.0 == "Willow" })
    assert_true(willow_rows.length() >= 1, msg="Willow row visible: \{at}")
    let last_w = willow_rows[willow_rows.length() - 1]
    t.tap(last_w.1 + last_w.3 / 2.0, last_w.2 + last_w.4 / 2.0)
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() == Setting(StationBackup("ws1/st1")), msg="navigated to StationBackup: \{at}")
  }
  // 3. Per-station StationBackup page: flat config, acceptOthers, S3 form, 1.3x scale, English + 320px narrow
  for (w, platform) in [(390.0, 2), (1280.0, 0)] {
    let at = "\{w} platform \{platform}"
    let calls : Array[(String, Json)] = []
    let t = setting_tester(StationBackup("ws1/st1"), w, platform~, mode="settings-backup-station", h=2600.0, over=fn(s) {
      {
        ..s,
        call: fn(name, params, done) {
          if name.has_prefix("copies.") {
            calls.push((name, params))
            if name == "copies.testS3" {
              done(Ok(@settings.obj([("ok", Json::boolean(true))])))
              return
            }
            if name == "copies.setSettings" {
              done(
                Ok(
                  @settings.obj([
                    (
                      "generatedKeys",
                      @settings.obj([("r2-new", Json::string("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))]),
                    ),
                  ]),
                ),
              )
              return
            }
          }
          (s.call)(name, params, done)
        },
      }
    })
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("已备份到 Cedar 和 Cloudflare R2 · 2 分钟前") is Some(_), msg="summary: \{at}")
    assert_true(t.find("备份记录") is Some(_), msg="history heading: \{at}")
    assert_true(t.find("同步成功 · 42 个聊天 · 18.4 MB") is Some(_), msg="history ok: \{at}")
    // (each station that keeps its backups, a row under the line: how far what it holds goes)
    assert_true(t.find("2 分钟前已备份到最新") is Some(_), msg="keeper Cedar: \{at}")
    assert_true(t.find("聊天已备份到最新（1 分钟前），会话记录还差 33012 个文件") is Some(_), msg="keeper Elm: \{at}")
    assert_true(t.find("Elm") is Some(_), msg="keeper Elm name: \{at}")
    assert_true(t.find("AWS S3") is Some(_), msg="history AWS S3 target: \{at}")
    assert_true(t.find("同步失败 · R2 / S3 · 无法连接") is Some(_), msg="history AWS S3 fail: \{at}")
    assert_true(t.find("备份方式") is Some(_), msg="mode label: \{at}")
    assert_true(t.find("Cedar") is Some(_), msg="peer Cedar: \{at}")
    assert_true(t.find("不接收他人备份") is Some(_), msg="peer Aspen declined: \{at}")
    assert_true(t.find("当前离线") is Some(_), msg="peer Birch offline: \{at}")
    assert_true(t.find("允许替其他 Station 存备份") is Some(_), msg="acceptOthers switch: \{at}")
    assert_true(t.find("R2 / S3 对象存储") is Some(_), msg="s3 heading: \{at}")
    assert_true(t.find("Cloudflare R2") is Some(_), msg="s3 target name: \{at}")
    assert_true(t.find("stillfail-backups") is Some(_), msg="s3 bucket: \{at}")
    assert_true(t.find("密钥指纹 ab12cd34") is Some(_), msg="s3 key fingerprint: \{at}")
    assert_eq(t.audit(), [], msg="audit station backup \{at}: \{Repr(t.audit())}")
    assert_eq(t.squeeze_faults(), [], msg="squeeze station backup \{at}: \{Repr(t.squeeze_faults())}")
    // 1.3x font scale check
    t.set_font_scale(1.3)
    t.run_for(@ui.move_most_ms)
    assert_eq(t.squeeze_faults(), [], msg="squeeze 1.3x \{at}: \{Repr(t.squeeze_faults())}")
    t.set_font_scale(1.0)
    t.run_for(@ui.move_most_ms)
    // Clicking 刷新 triggers copies.history again
    let hist_before = calls.filter(fn(c) { c.0 == "copies.history" }).length()
    t.tap_text("刷新")
    t.run_for(@ui.move_most_ms)
    let hist_after = calls.filter(fn(c) { c.0 == "copies.history" }).length()
    assert_eq(hist_after, hist_before + 1, msg="refresh triggers copies.history: \{at}")
    // Toggle acceptOthers switch -> copies.setSettings for ws1/st1 only
    t.click(Switch, label="允许替其他 Station 存备份")
    t.run_for(@ui.move_most_ms)
    assert_true(
      calls.iter().any(fn(c) { c.0 == "copies.setSettings" && text(Some(c.1), "station") == "ws1/st1" && !flag(Some(c.1), "acceptOthers") }),
      msg="acceptOthers call: \{at}",
    )
    // Click 添加 to open S3 add form dialog/sheet directly and audit it
    t.tap_text("添加")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("添加 R2 / S3 对象存储") is Some(_), msg="s3 form title: \{at}")
    assert_true(t.find("测试连接") is Some(_), msg="test button: \{at}")
    assert_eq(t.audit(), [], msg="audit form \{at}: \{Repr(t.audit())}")
    assert_eq(t.squeeze_faults(), [], msg="squeeze form \{at}: \{Repr(t.squeeze_faults())}")
    t.click(Button, label="取消")
    t.run_for(@ui.move_most_ms)
    // English + 320px narrow check
    @sf.set_language(Some("en"))
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("R2 / S3 storage") is Some(_), msg="en s3 heading: \{at}")
    assert_eq(t.audit(), [], msg="en audit \{at}: \{Repr(t.audit())}")
    assert_eq(t.squeeze_faults(), [], msg="en squeeze \{at}: \{Repr(t.squeeze_faults())}")
    @sf.set_language(None)
  }
  // 4. 320px narrow Backup & StationBackup clean
  let n320 = setting_tester(StationBackup("ws1/st1"), 320.0, platform=2, mode="settings-backup-station", h=2600.0)
  n320.run_for(@ui.move_most_ms)
  assert_true(n320.find("备份记录") is Some(_), msg="320px history heading")
  assert_eq(n320.audit(), [], msg="320px audit: \{Repr(n320.audit())}")
  assert_eq(n320.squeeze_faults(), [], msg="320px squeeze: \{Repr(n320.squeeze_faults())}")
  // 4b. Empty history and error history states
  let empty_h = setting_tester(StationBackup("ws1/st1"), 390.0, platform=2, mode="settings-backup-station", h=2400.0, over=fn(s) {
    {
      ..s,
      call: fn(name, params, done) {
        if name == "copies.history" {
          done(Ok(@settings.obj([("records", Json::array([]))])))
          return
        }
        (s.call)(name, params, done)
      },
    }
  })
  empty_h.run_for(@ui.move_most_ms)
  assert_true(empty_h.find("暂无备份记录") is Some(_), msg="empty history message")
  assert_eq(empty_h.audit(), [], msg="empty history audit")
  let err_h = setting_tester(StationBackup("ws1/st1"), 390.0, platform=2, mode="settings-backup-station", h=2400.0, over=fn(s) {
    {
      ..s,
      call: fn(name, params, done) {
        if name == "copies.history" {
          done(Err(@settings.obj([("code", Json::string("not_found")), ("message", Json::string("404 Not Found"))])))
          return
        }
        (s.call)(name, params, done)
      },
    }
  })
  err_h.run_for(@ui.move_most_ms)
  assert_true(err_h.find("当前 Station 版本暂不支持查看备份记录") is Some(_), msg="unsupported history message")
  assert_eq(err_h.audit(), [], msg="error history audit")
  // 5. Offline station hides write controls
  let off = setting_tester(StationBackup("ws1/st1"), 390.0, platform=2, mode="settings-station-away", h=1600.0)
  off.run_for(@ui.move_most_ms)
  assert_true(off.find("Station 当前离线，上线后可修改备份配置。") is Some(_), msg="offline notice")
  assert_true(off.find("备份方式") is None, msg="no write controls when offline")
  assert_eq(off.audit(), [], msg="offline audit")
  // 6. Restore from S3 on StationBackup passes fromS3 (not fromStation)
  let restore_calls : Array[(String, Json)] = []
  let r = setting_tester(StationBackup("ws1/st1"), 390.0, platform=2, mode="settings-backup-restore-s3", h=2400.0, over=fn(s) {
    {
      ..s,
      call: fn(name, params, done) {
        if name == "copies.restore" {
          restore_calls.push((name, params))
          done(Ok(@settings.obj([])))
          return
        }
        (s.call)(name, params, done)
      },
    }
  })
  r.run_for(@ui.move_most_ms)
  assert_true(r.find("Old Mac 的 128 个聊天 · 来自 Cloudflare R2") is Some(_), msg="s3 offer line")
  assert_eq(r.audit(), [], msg="audit restore s3")
  assert_eq(r.squeeze_faults(), [], msg="squeeze restore s3")
  r.click(Button, label="恢复到这台")
  r.run_for(@ui.move_most_ms)
  let btns = r.words().filter(fn(w) { w.0 == "恢复到这台" })
  assert_true(btns.length() >= 1)
  let last = btns[btns.length() - 1]
  r.tap(last.1 + last.3 / 2.0, last.2 + last.4 / 2.0)
  r.run_for(@ui.move_most_ms)
  assert_eq(restore_calls.length(), 1)
  assert_eq(text(Some(restore_calls[0].1), "fromS3"), "r2-1")
  assert_eq(text(Some(restore_calls[0].1), "fromStation"), "")
}

///|
test "an away station's 设置 shows read-only snapshot of software, permissions and system settings with no write actions" {
  for (w, platform) in page_cases {
    let calls : Array[String] = []
    let t = setting_tester(Station("ws1/st1"), w, platform~, mode="settings-station-away", h=2400.0, over=fn(s) {
      { ..s, call: fn(name, params, done) {
        calls.push(name)
        (s.call)(name, params, done)
      } }
    })
    t.run_for(@ui.move_most_ms)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("离线前快照，连接后可修改") is Some(_), msg=at)
    assert_true(t.find("软件与更新") is Some(_), msg="software section: \{at}")
    assert_true(t.find("1970/1/1") is None, msg="no epoch timestamp: \{at}")
    assert_true(t.find("下载更新包超时，请检查网络连接后重试") is Some(_), msg="failed update reason: \{at}")
    assert_true(t.query(Button, label="更新") is None, msg="no update button: \{at}")
    assert_true(t.query(Button, label="安装") is None, msg="no install button: \{at}")
    assert_true(t.query(Button, label="检查更新") is None, msg="no check button: \{at}")
    assert_true(t.find("自动更新") is None, msg="no auto update switch: \{at}")
    assert_true(t.find("屏幕录制") is Some(_), msg="cached grant: \{at}")
    assert_true(t.find("辅助功能") is Some(_), msg="cached grant 2: \{at}")
    assert_true(t.query(Button, label="申请") is None, msg="no grant request button: \{at}")
    assert_true(t.find("Agent 环境变量") is Some(_), msg="cached env row: \{at}")
    assert_true(t.find("在浏览器里登录") is None, msg="no login card: \{at}")
    t.tap_text("Agent 环境变量")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("HTTPS_PROXY") is Some(_), msg="read-only env key: \{at}")
    assert_true(t.find("http://127.0.0.1:7890") is Some(_), msg="read-only env val: \{at}")
    assert_true(calls.iter().all(fn(c) { c != "agentEnv.form.open" }), msg="no form open call offline: \{at}")
    assert_eq(t.audit(), [], msg="audit: \{at}")
    assert_eq(t.squeeze_faults(), [], msg="squeeze: \{at}")
  }
}

///|
test "an away station's 概览 shows diagnostics card with copy and cached resource snapshot across widths, 1.3x scale and English" {
  for (w, platform) in [(320.0, 2), (390.0, 2), (1280.0, 0)] {
    let t = setting_tester(Station("ws1/st1"), w, platform~, mode="settings-station-away", h=2400.0, ready=fn() {
      @settings.station_parts["ws1/st1"] = "overview"
    })
    t.run_for(@ui.move_most_ms)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("连接诊断") is Some(_), msg="diag title: \{at}")
    assert_true(t.find("复制诊断") is Some(_), msg="copy button: \{at}")
    assert_true(t.find("无法连接：可能已离线，或受中继、防火墙影响") is Some(_), msg="head warning: \{at}")
    assert_true(t.find("连接超时，未收到 station 响应") is Some(_), msg="diag detail: \{at}")
    assert_true(t.find("已连续失败 5 次 · 下次重试 15:52:10（每 10 分钟）") is Some(_), msg="diag retry: \{at}")
    assert_true(t.find("上次在线") is None, msg="no duplicate lastOnline row: \{at}")
    assert_true(t.find("当前延迟") is None, msg="no offline current latency line: \{at}")
    assert_true(t.find("局域网直连") is Some(_), msg="diag way 1: \{at}")
    assert_true(t.find("东京中继") is Some(_), msg="diag way 3: \{at}")
    assert_true(t.find("离线前快照") is Some(_), msg="resources snapshot note: \{at}")
    assert_true(t.find("1.9") is Some(_), msg="cached memory dial: \{at}")
    t.tap_text("复制诊断")
    t.draw()
    assert_true(@sfbase.toast_words().contains("已复制诊断信息"), msg="copied toast: \{at}")
    for scale in [1.0, 1.3] {
      t.set_font_scale(scale)
      t.run_for(@ui.move_most_ms)
      let a = if scale > 1.0 && w < 390.0 {
        t.audit().filter(fn(f) { !f.contains("meter_atoms_node.mbt") })
      } else {
        t.audit()
      }
      let s = if scale > 1.0 && w < 390.0 {
        t.squeeze_faults().filter(fn(f) { !f.contains("meter_atoms_node.mbt") })
      } else {
        t.squeeze_faults()
      }
      assert_eq(a, [], msg="audit \{at} scale \{scale}: \{Repr(a)}")
      assert_eq(s, [], msg="squeeze \{at} scale \{scale}: \{Repr(s)}")
    }
    t.set_font_scale(1.0)
    @sf.set_language(Some("en"))
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("Diagnostics") is Some(_), msg="en diag title: \{at}")
    let ea = t.audit()
    let es = t.squeeze_faults()
    assert_eq(ea, [], msg="en audit \{at}: \{Repr(ea)}")
    assert_eq(es, [], msg="en squeeze \{at}: \{Repr(es)}")
    @sf.set_language(None)
  }
}

///|
test "a station's page, its parts chosen by its choice: 设置 pressed shows it" {
  let t = station_tester("ws1/st1")
  match t.semantics().filter(fn(s) { s.role != Link && !s.hidden && s.label == "设置" }) {
    [tab, ..] => {
      let (x, y, w, h) = tab.rect
      t.tap(x + w / 2.0, y + h / 2.0)
    }
    [] => fail("no 设置")
  }
  t.draw()
  assert_eq(@settings.station_parts.get("ws1/st1"), Some("settings"))
  assert_true(t.find("Agent 环境变量") is Some(_))
}

///|
test "the station's GPUs are each visible on narrow and wide pages with either input" {
  for (w, platform) in page_cases {
    let t = setting_tester(Station("ws1/st1"), w, platform~, mode="settings-station-gpu", h=2400.0)
    t.run_for(@ui.move_most_ms)
    assert_eq(t.squeeze_faults(), [])
    assert_true(t.find("GPU 1 空闲率") is Some(_))
    assert_true(t.find("显存剩 20/24G") is Some(_))
    assert_true(t.find("GPU 2 空闲率") is Some(_))
    assert_true(t.find("显存剩 23/24G") is Some(_))
    assert_true(t.words().filter(fn(word) { word.0 == "NVIDIA GeForce RTX 4090" }).length() == 2)
  }
}

///|
test "more than three GPUs continue on another row" {
  for (w, platform) in [(390.0, 2), (1280.0, 0)] {
    let t = setting_tester(Station("ws1/st1"), w, platform~, mode="settings-station-gpu-many", h=2400.0)
    t.run_for(@ui.move_most_ms)
    assert_eq(t.squeeze_faults(), [])
    let cpu = drawn(t, "CPU 空闲率")
    let first = drawn(t, "GPU 1 空闲率")
    let fourth = drawn(t, "GPU 4 空闲率")
    if w > 1000.0 {
      assert_true((first.1 - cpu.1).abs() < 0.5, msg="GPU and the other resources share the first wide row")
    }
    assert_true(fourth.1 > first.1 + first.3, msg="the fourth GPU starts a new row")
  }
}

///|
test "a Windows station's 设置 switches running as administrator, waiting while Windows asks, with how it last failed" {
  let asked : Array[Json] = []
  let t = setting_tester(
    Station("ws1/st1"),
    390.0,
    platform=2,
    h=2400.0,
    over=fn(s) {
      {
        ..s,
        call: fn(name, params, done) {
          if name == "elevation.set" {
            asked.push(params)
          }
          (s.call)(name, params, done)
        },
      }
    },
    ready=fn() {
      @settings.station_parts["ws1/st1"] = "settings"
      @settings.fixture_elevation(
        Some(
          @settings.obj([
            ("on", Json::boolean(false)),
            ("busy", Json::boolean(false)),
            ("line", Json::string("agent 的命令都以管理员权限运行")),
            ("failed", Json::string("2 分钟内没人确认 UAC，已取消，设置没有改变")),
            ("canChange", Json::boolean(true)),
          ]),
        ),
      )
    },
  )
  t.run_for(@ui.move_most_ms)
  scrolled_to(t, 390.0, "以管理员身份运行")
  assert_true(t.find("2 分钟内没人确认 UAC，已取消，设置没有改变") is Some(_), msg=t.words().map(fn(w) { w.0 }).join("|"))
  t.click(Switch, label="以管理员身份运行")
  t.draw()
  assert_eq(asked.length(), 1, msg="switched")
  assert_eq(field(Some(asked[0]), "on"), Some(Json::boolean(true)))
  // (a change under way: the switch waits, not pressed again)
  t.run_for(@ui.move_most_ms)
  t.click(Switch, label="以管理员身份运行")
  t.draw()
  assert_eq(asked.length(), 1, msg="not again while it is under way")
}

///|
test "a Windows station's screen service switch shows its line and failure and toggles once while busy" {
  let asked : Array[Json] = []
  let t = setting_tester(
    Station("ws1/st1"),
    390.0,
    platform=2,
    h=2400.0,
    over=fn(s) {
      {
        ..s,
        call: fn(name, params, done) {
          if name == "screenService.set" {
            asked.push(params)
          }
          (s.call)(name, params, done)
        },
      }
    },
    ready=fn() {
      @settings.station_parts["ws1/st1"] = "settings"
      @settings.fixture_screen_service(
        Some(
          @settings.obj([
            ("on", Json::boolean(false)),
            ("busy", Json::boolean(false)),
            ("line", Json::string("远程查看屏幕时可显示并点击 UAC 弹窗、管理员窗口和锁屏界面")),
            ("failed", Json::string("UAC 被拒绝，设置没有改变")),
            ("canChange", Json::boolean(true)),
          ]),
        ),
      )
    },
  )
  t.run_for(@ui.move_most_ms)
  scrolled_to(t, 390.0, "远程控制 UAC 与锁屏")
  assert_true(t.find("UAC 被拒绝，设置没有改变") is Some(_), msg=t.words().map(fn(w) { w.0 }).join("|"))
  t.click(Switch, label="远程控制 UAC 与锁屏")
  t.draw()
  assert_eq(asked.length(), 1, msg="switched")
  assert_eq(field(Some(asked[0]), "on"), Some(Json::boolean(true)))
  t.run_for(@ui.move_most_ms)
  t.click(Switch, label="远程控制 UAC 与锁屏")
  t.draw()
  assert_eq(asked.length(), 1, msg="not again while it is under way")
}

///|
test "a station's ⋯ restarts it" {
  let asked : Array[(String, Json)] = []
  let t = setting_tester(Station("ws1/st1"), 390.0, platform=2, h=2400.0,
    over=fn(s) { { ..s, call: fn(name, params, done) {
      if name == "station.restart" { asked.push((name, params)) }
      (s.call)(name, params, done)
    } } })
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="更多")
  t.draw()
  presented_in(t)
  t.tap_text("重启 station")
  t.draw()
  assert_eq(asked.length(), 1, msg="asked")
  assert_true(field(Some(asked[0].1), "station") is Some(String(_)))
}

///|
test "a station's 设置 switches sending its log to still.fail off" {
  let asked : Array[Json] = []
  let t = setting_tester(
    Station("ws1/st1"),
    390.0,
    platform=2,
    h=2400.0,
    over=fn(s) {
      {
        ..s,
        call: fn(name, params, done) {
          if name == "diagnostics.setLogs" {
            asked.push(params)
          }
          (s.call)(name, params, done)
        },
      }
    },
    ready=fn() { @settings.station_parts["ws1/st1"] = "settings" },
  )
  t.run_for(@ui.move_most_ms)
  scrolled_to(t, 390.0, "发送运行日志给 still.fail")
  assert_true(t.find("发送运行日志给 still.fail") is Some(_), msg=t.words().map(fn(w) { w.0 }).join("|"))
  t.click(Switch, label="发送运行日志给 still.fail")
  t.draw()
  assert_eq(asked.length(), 1, msg="switched")
  assert_eq(field(Some(asked[0]), "logs"), Some(Json::boolean(false)))
}

///|
test "a station's page opened again begins at its overview" {
  let t = station_tester("ws1/st1", part="settings")
  @settings.left(Station("ws1/st1"))
  t.draw()
  assert_true(t.find("文件") is Some(_))
}

///|
/// Maple (ws1/st2, offline in the fixture) as this machine's station, as still.fail's desktop app left it on a Mac
/// (`own_station`: the host's words for it), its page open with a mouse at `w`.
fn this_mba_tester(own_station : String, w? : Double = 390.0) -> @ui.Tester {
  // (this machine's station as the system says it from the start: the host's)
  let t = setting_tester(Station("ws1/st2"), w, platform=0, h=2400.0, ready=fn() {
    @sfbase.machine_here.val = Some("ws1/st2")
  }, host=fn(h) { h.set_app_said("local_station", own_station) })
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "this machine's station not running here: its page says it stopped and offers 启动, not 重试; pressed, made a service" {
  for w in [390.0, 1100.0] {
    let t = this_mba_tester((
      #|{"data":"~/.stillfail","runner":"none","workspace":{"id":"ws1","station":"st2","name":"星火工作室","stationName":"Maple","removed":false}}
      ),
      w~,
    )
    let at = "\{w}"
    assert_true(t.find("已停止") is Some(_), msg=at)
    assert_true(t.query(Button, label="重试") is None, msg=at)
    t.click(Button, label="启动")
    t.frame()
    let acts = t.app_told("local_station_act")
    assert_eq(acts.length(), 1, msg=at)
    assert_true(acts[0].has_prefix("update {"), msg="\{at}: \{acts[0]}")
  }
}

///|
test "this machine's station being installed: its page says so, its 启动 busy; one running here, or another machine's, tried again" {
  let t = this_mba_tester((
    #|{"data":"~/.stillfail","runner":"none","doing":"update","percent":42,"workspace":{"id":"ws1","station":"st2","name":"星火工作室","stationName":"Maple","removed":false}}
    ),
  )
  assert_true(t.find("正在更新") is Some(_))
  assert_true(t.query(Button, label="重试") is None)
  // running here (the app not reaching it yet): tried again, as any
  let t = this_mba_tester((
    #|{"data":"~/.stillfail","runner":"service","service":{"kind":"launchd","name":"fail.still.station"},"workspace":{"id":"ws1","station":"st2","name":"星火工作室","stationName":"Maple","removed":false}}
    ),
  )
  assert_true(t.query(Button, label="重试") is Some(_))
  assert_true(t.query(Button, label="启动") is None)
  // another machine's: tried again
  let t = setting_tester(Station("ws1/st2"), 390.0, platform=0, h=2400.0, ready=fn() {
    @sfbase.machine_here.val = Some("ws1/st1")
  }, host=fn(h) {
    h.set_app_said("local_station", (
      #|{"data":"~/.stillfail","runner":"none","workspace":{"id":"ws1","station":"st1","name":"星火工作室","stationName":"Willow","removed":false}}
      ),
    )
  })
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="重试") is Some(_))
  assert_true(t.query(Button, label="启动") is None)
}

///|
test "a station's 进程: what still.fail uses of it, whose by whose, the overview's line opening it" {
  let t = station_tester("ws1/st1")
  // the overview's line: what still.fail uses, opening its 进程
  assert_true(t.find("still.fail 占用") is Some(_), msg=t.words().map(fn(w) { w.0 }).join("|"))
  t.tap_text("still.fail 占用")
  t.draw()
  assert_eq(@settings.station_parts.get("ws1/st1"), Some("processes"))
  // its totals, its table by whose, the first open to its processes (a chat's own one to end)
  assert_true(t.find("508 MB") is Some(_), msg="the memory's total")
  assert_true(t.find("修一下登录") is Some(_), msg="a chat's group")
  assert_true(t.find("node") is Some(_), msg="the first group open")
  assert_true(t.locate("icon:stop").length() == 1, msg="the chat's process to end, the agent's not")
  // flat: every process, whose it is beside it
  t.tap_text("平铺")
  t.draw()
  assert_true(t.find("stillfail") is Some(_))
  let node = drawn(t, "node")
  let whose = drawn(t, "修一下登录")
  assert_eq(node.1 + node.3 / 2.0, whose.1 + whose.3 / 2.0, msg="its chat beside its name")
}

///|
test "a station's 进程: each total's line under its label at the tile's end, as far in as the label at its start" {
  for case in [(390.0, 2), (720.0, 0), (1280.0, 0)] {
    let (w, platform) = case
    let t = station_tester("ws1/st1", part="processes", w~, platform~)
    let label = drawn(t, "CPU")
    let sub = drawn(t, "占 10 核的 2%")
    let tile = ground_round(t, label)
    let start = label.0 - tile.0
    let end = tile.0 + tile.2 - (sub.0 + sub.2)
    assert_true((start - end).abs() < 0.5, msg="\{w} platform \{platform}: the sub \{start} in at the start, \{end} at the end")
  }
}

///|
test "a station's 进程 on a wide page: the choice of whose at the bar's start, of how at its end, where the tiles end" {
  for case in [(720.0, 0), (1280.0, 0)] {
    let (w, platform) = case
    assert_true(laid_wide(w))
    let t = station_tester("ws1/st1", part="processes", w~, platform~)
    let how = ground_round(t, drawn(t, "平铺"))
    let last = ground_round(t, drawn(t, "↓ 1.6 KB/s"))
    assert_true((how.0 + how.2 - (last.0 + last.2)).abs() < 0.5, msg="\{w} platform \{platform}: 分组/平铺 ends at \{how.0 + how.2}, the tiles at \{last.0 + last.2}")
  }
}

///|
/// The least ground drawn round words drawn at `r` (x, y, w, h): what they are on.
fn ground_round(t : @ui.Tester, r : (Double, Double, Double, Double)) -> (Double, Double, Double, Double) raise {
  let (cx, cy) = (r.0 + r.2 / 2.0, r.1 + r.3 / 2.0)
  let mut best : (Double, Double, Double, Double)? = None
  for g in t.drawn_rects() {
    let (x, y, gw, gh, _) = g
    if cx >= x && cx <= x + gw && cy >= y && cy <= y + gh {
      match best {
        Some(b) if b.2 * b.3 <= gw * gh => ()
        _ => best = Some((x, y, gw, gh))
      }
    }
  }
  match best {
    Some(b) => b
    None => fail("no ground round \{Repr(r)}")
  }
}

///|
/// Where words `s` are drawn (x, y, w, h): the first words that are just them.
fn drawn(t : @ui.Tester, s : String) -> (Double, Double, Double, Double) raise {
  match t.words().search_by(fn(w) { w.0 == s }) {
    Some(i) => {
      let (_, x, y, w, h, _) = t.words()[i]
      (x, y, w, h)
    }
    None => fail("no \{s} drawn")
  }
}

///|
/// Each of `columns` (the words in it, its head's among them) ends at one edge, as a table's figures do.
fn lined_up(t : @ui.Tester, columns : Array[Array[String]]) -> Unit raise {
  for column in columns {
    let ends = []
    for s in column {
      let (x, _, w, _) = drawn(t, s)
      ends.push(x + w)
    }
    for i, e in ends {
      assert_true((e - ends[0]).abs() < 0.5, msg="\{column[i]} ends at \{e}, \{column[0]} at \{ends[0]}")
    }
  }
}

///|
/// The 进程's columns as the settings' fixture has them: CPU (sorted by), memory, disk, each with its group's figures,
/// its first group's processes' (open) and the other chat's.
let processes_columns : Array[Array[String]] = [
  ["CPU ↓", "25.9%", "13.9%", "12.0%", "14.1%", "2.8%"],
  ["59 MB", "18 MB", "41 MB", "980 MB", "363 MB"],
  ["2.9 MB/s", "1.0 MB/s", "1.9 MB/s", "13 KB/s"],
]

///|
test "a station's 进程 at a phone's width: its totals two to a line, each row's names over its figures, its columns lined up" {
  let t = station_tester("ws1/st1", part="processes")
  assert_eq(t.squeeze_faults(), [])
  let cpu = drawn(t, "20.5%")
  let memory = drawn(t, "508 MB")
  let disk = drawn(t, "↓ 2.9 MB/s")
  assert_eq(cpu.1, memory.1, msg="two to a line")
  assert_true(disk.1 > cpu.1 + cpu.3, msg="the other two under them")
  // a chat's title on a line of its own, its figures under it at the row's end
  let title = drawn(t, "修一下登录")
  let figure = drawn(t, "25.9%")
  assert_true(figure.1 >= title.1 + title.3, msg="its figures under its name")
  assert_true(t.find("名称") is None, msg="no head over the names: they have their own line")
  lined_up(t, processes_columns)
  // flat: the same
  t.tap_text("平铺")
  t.draw()
  assert_eq(t.squeeze_faults(), [])
  assert_true(drawn(t, "13.9%").1 > drawn(t, "node").1, msg="a process's figures under its name and whose")
}

///|
test "a station's 进程 on a computer's wide page: its totals four in a row, each row on one line, its columns lined up" {
  let t = station_tester("ws1/st1", part="processes", w=1280.0, platform=0)
  assert_eq(t.squeeze_faults(), [])
  let cpu = drawn(t, "20.5%")
  let net = drawn(t, "↓ 1.6 KB/s")
  assert_eq(cpu.1, net.1, msg="four in a row")
  let title = drawn(t, "修一下登录")
  let figure = drawn(t, "25.9%")
  assert_eq(title.1 + title.3 / 2.0, figure.1 + figure.3 / 2.0, msg="its figures beside its name")
  assert_true(t.find("名称") is Some(_), msg="the names' head")
  lined_up(t, processes_columns)
}

///|
test "a station's 进程 with keyboard and mouse: a chat's process's stop is reached by Tab, said by what it ends, seen as it has the focus" {
  let t = station_tester("ws1/st1", part="processes", w=1280.0, platform=0)
  assert_eq(t.squeeze_faults(), [])
  // (no row takes the focus: the stop is a stop of its own, found by Tab from the page's top)
  let mut found = false
  for _ in 0..<80 {
    t.tab()
    t.draw()
    match t.focused() {
      Some(n) if n.label == "结束 node" => {
        found = true
        break
      }
      _ => ()
    }
  }
  assert_true(found, msg="Tab reaches 结束 node")
  assert_eq(t.focused().map(fn(n) { n.role is Button }), Some(true))
  assert_true(t.reachable("icon:stop").length() == 1, msg="its stop shows as it has the focus")
  // the agent's own process, not to be ended, has none
  assert_true(t.all(Button, label="结束 claude").is_empty())
}

///|
test "a station's 进程 at a phone's width: a process's stop sits on its name's line, not centred on its name and figures" {
  let t = station_tester("ws1/st1", part="processes")
  let stops = t.all(Button, label="结束 node")
  assert_eq(stops.length(), 1, msg="its stop shows where the hand is a finger")
  let (_, sy, _, sh) = stops[0].rect
  let name = drawn(t, "node")
  let figure = drawn(t, "13.9%")
  assert_true(figure.1 >= name.1 + name.3, msg="its figures under its name")
  assert_true((sy + sh / 2.0 - (name.1 + name.3 / 2.0)).abs() < 0.5, msg="on its name's line: \{Repr(stops[0].rect)}, \{Repr(name)}")
  lined_up(t, processes_columns)
}

///|
/// A station's variables (station_node.mbt station_env_editor_node, in its page's 设置): the field shows the core's draft as
/// it changes while nothing typed here waits on it.
test "the variables' field follows the core's text that comes after the page opened" {
  let env : @signals.Signal[(String, Int)] = @signals.signal(("", 1))
  let over = fn(base : Source) -> Source {
    {
      ..base,
      topic_read: fn(name, params) {
        if name == "agentEnvForm" {
          let (words, v) = env.get()
          {
            value: Some(
              Json::object({
                "text": Json::string(words),
                "lines": Json::array([]),
                "errors": Json::number(0.0),
                "dirty": Json::boolean(false),
                "pending": Json::boolean(false),
              }),
            ),
            error: None,
            version: v,
          }
        } else {
          base.topic(name, params).get().snapshot()
        }
      },
    }
  }
  // in the page's 设置, its variables' editor in it (a manager's), the page tall enough for all of it
  let t = setting_tester(Station("ws1/st1"), 390.0, platform=2, h=2400.0, over~, ready=fn() {
    @settings.station_parts["ws1/st1"] = "settings"
  })
  t.run_for(@ui.move_most_ms)
  t.tap_text("Agent 环境变量")
  t.draw()
  // opened on the text before a save the core tells a moment later
  let in_field = fn() { t.semantics().iter().any(fn(n) { n.role is TextField && n.value == "E2E_A=1" }) }
  assert_false(in_field())
  env.set(("E2E_A=1", 2))
  t.draw()
  t.draw()
  // (the field's words: what its editor holds, as it is read out)
  assert_true(in_field(), msg="the core's text, come after the page opened, in the field")
}

///|
/// All of what field `f` holds typed over with `words`, as a person would (picked whole, then typed: an edit of theirs,
/// not the app's Field::set).
fn type_over(t : @ui.Tester, f : @ui.Field, words : String) -> Unit {
  f.pick(0, f.text().length())
  t.type_text(words)
}

///|
test "two station variables editors share the draft without sharing editor state" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let env : @signals.Signal[(String, Int, Bool)] = @signals.signal(("E2E_A=1", 1, false))
  let saving = @signals.signal(false)
  let edits : Array[Json] = []
  let base = @sffixture.fixture("settings")
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      if name == "agentEnvForm" {
        let (words, version, dirty) = env.get()
        { value: Some({ "text": Json::string(words), "lines": [], "errors": 0, "dirty": Json::boolean(dirty), "pending": Json::boolean(saving.get()) }), error: None, version }
      } else {
        base.topic(name, params).get().snapshot()
      }
    },
    call: fn(name, params, done) {
      if name == "agentEnv.form.edit" {
        edits.push(params)
        if flag(field(Some(params), "input"), "reset") {
          env.set(("E2E_A=1", 5, false))
        }
        done(Ok(Json::null()))
      } else {
        (base.call)(name, params, done)
      }
    },
  }
  // (two pages' editors of one station's draft: each its own field, each in a card's room as on its page, the second's
  // field frame reaching out to its card's edge (card_block_out) not over the first's buttons)
  let a = @ui.Field::new()
  let b = @ui.Field::new()
  let core = @sfbase.settings_core(src, rig_workspace)
  let t = station_part_tester(fn(p) {
    p.box(fn(k) { k.padding(Is((16.0, 16.0, 16.0, 16.0))) |> ignore; station_env_editor_node(k, core, "ws1/st1", a) }) |> ignore
    p.box(fn(k) { k.padding(Is((16.0, 16.0, 16.0, 16.0))) |> ignore; station_env_editor_node(k, core, "ws1/st1", b) }) |> ignore
  }, w=390.0, h=900.0, platform=1)
  t.check_looks(false)
  t.set_rows_on_pixels(true)
  t.draw()
  assert_eq(a.text(), "E2E_A=1")
  assert_eq(b.text(), "E2E_A=1")
  a.pick(0, 0)
  b.pick(3, 3)
  assert_eq(a.selection(), (0, 0), msg="each editor owns its selection")
  assert_eq(b.selection(), (3, 3))

  let fields = t.all(TextField, label=env_placeholder)
  assert_eq(fields.length(), 2)
  let (x, y, w, _) = fields[0].rect
  t.tap(x + w - 8.0, y + 8.0)
  a.pick(a.text().length(), a.text().length())
  t.type_text("2")
  t.draw()
  assert_eq(a.text(), "E2E_A=12")
  assert_eq(b.text(), "E2E_A=12", msg="the second editor follows an edit before the core answers")
  type_over(t, a, "E2E_A=1")
  t.draw()
  t.draw()
  assert_eq(b.text(), "E2E_A=1", msg="reverting to the old core value is an edit too")
  type_over(t, a, "E2E_A=123")
  t.draw()
  t.draw()
  assert_eq(b.text(), "E2E_A=123")
  assert_eq(edits.length(), 3)

  env.set(("E2E_A=12", 2, true))
  t.draw()
  t.draw()
  assert_eq(a.text(), "E2E_A=123", msg="an older core answer does not replace a newer edit")
  assert_eq(b.text(), "E2E_A=123")
  assert_eq(edits.length(), 3, msg="an older answer does not send another edit")
  env.set(("E2E_A=123", 3, true))
  t.draw()
  t.draw()
  env.set(("E2E_A=4", 4, true))
  t.draw()
  t.draw()
  assert_eq(a.text(), "E2E_A=4", msg="later core changes reach both editors")
  assert_eq(b.text(), "E2E_A=4")
  saving.set(true)
  t.draw()
  type_over(t, a, "E2E_A=45")
  t.draw()
  t.draw()
  assert_eq(b.text(), "E2E_A=45")
  assert_eq(edits.length(), 3, msg="an edit made while saving is not sent until saving finishes")
  saving.set(false)
  t.draw()
  t.draw()
  assert_eq(edits.length(), 4, msg="the queued edit is sent after saving")
  t.tap_text(@sf.t("common.cancel"))
  t.draw()
  t.draw()
  assert_eq(a.text(), "E2E_A=1", msg="cancel restores the core's draft on both pages (\{edits.length()} edits: \{edits.map(fn(e) { e.stringify() }).join(" ")})")
  assert_eq(b.text(), "E2E_A=1")
  assert_eq(edits.length(), 5, msg="cancel sends one reset and does not resend the old edit")
}

///|
test "on this machine's own page its display says so and opens nothing; its browser's tab opens" {
  let t = setting_tester(Station("ws1/st1"), 390.0, platform=0, h=2400.0, ready=fn() {
    @sfbase.machine_here.val = Some("ws1/st1")
  })
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("这是本机的屏幕") is Some(_), msg=t.words().map(fn(w) { w.0 }).join("|"))
  assert_true(t.find("3024 × 1964 · 无人在看") is None)
  t.tap_text("Willow 的屏幕")
  t.draw()
  assert_true(!(@sfbase.app.nav.top() is Screen(_)))
  t.tap_text("发布清单 - 文档")
  t.draw()
  assert_true(@sfbase.app.nav.top() is Screen(_))
}

///|
test "a station's overview: its browser one row opening it, the agents' pages and its screens in one section" {
  for (w, platform) in page_cases {
    let at = "\{w} platform \{platform}"
    @sfbase.reset()
    reset()
    @settings.reset()
    @sffixture.fixture_reset()
    @sf.presenters_reset()
    @sf.set_words(@sfbase.fill)
    let calls : Array[(String, Json)] = []
    let screens_topic : Json = {
      "browser": true,
      "control": true,
      "known": true,
      "outdated": false,
      "screens": [
        {
          "id": "desktop",
          "kind": "desktop",
          "title": "Willow 的屏幕",
          "width": 3024.0,
          "height": 1964.0,
          "line": "3024 × 1964 · 无人在看",
          "link": "",
        },
        {
          "id": "browser:u_mail",
          "kind": "browser",
          "userTab": true,
          "sleeping": false,
          "closable": true,
          "title": "收件箱 - Proton Mail",
          "width": 1280.0,
          "height": 800.0,
          "line": "mail.proton.me · 1280 × 800",
          "link": "",
        },
        {
          "id": "browser:u_gh",
          "kind": "browser",
          "userTab": true,
          "sleeping": true,
          "closable": true,
          "title": "GitHub",
          "width": 0.0,
          "height": 0.0,
          "line": "已休眠 · github.com",
          "link": "",
        },
        {
          "id": "browser:t1",
          "kind": "browser",
          "closable": true,
          "title": "Sign in · Anthropic",
          "width": 1280.0,
          "height": 800.0,
          "line": "浏览器标签页 · 1280 × 800",
          "link": "",
        },
      ],
    }
    let base = @sffixture.fixture("settings")
    let src : Source = {
      ..base,
      topic_read: fn(name, params) {
        let tp = base.topic(name, params).get().snapshot()
        if name == "screens" {
          { ..tp, value: Some(screens_topic) }
        } else {
          tp
        }
      },
      call: fn(name, params, done) {
        if name.has_prefix("screen.") { calls.push((name, params)) }
        done(Ok(Json::null()))
      },
    }
    let core = @sfbase.settings_core(src, rig_workspace)
    let here = fn() { @settings.here_of(core, rig_workspace.id, rig_workspace.name) }
    let s = fn() { @settings.station_of(core, here(), "ws1/st1") }
    let keys = station_overview_keys(core, here, s())
    assert_true(keys.contains("allScreens"), msg="allScreens key: \{at}")
    let t = station_part_tester(fn(p) {
      p.gap(Is(20.0)) |> ignore
      station_all_screens_node(p, core, here, s)
    }, w~, h=900.0, platform~)
    // a person's own pages: one row (how many in its note), none of them listed, nothing of their sleep
    assert_true(t.find("屏幕、浏览器与终端") is Some(_), msg=at)
    assert_true(t.find("打开浏览器") is Some(_), msg=at)
    assert_true(t.find("2 个标签页") is Some(_), msg=at)
    assert_true(t.find("收件箱 - Proton Mail") is None, msg=at)
    assert_true(t.find("已休眠") is None, msg=at)
    assert_true(t.find("Sign in · Anthropic") is Some(_), msg=at)
    assert_true(t.find("Willow 的屏幕") is Some(_), msg=at)
    let (_, screen_y) = t.find("Willow 的屏幕").unwrap()
    let (_, anthropic_y) = t.find("Sign in · Anthropic").unwrap()
    let (_, browser_y) = t.find("打开浏览器").unwrap()
    assert_true(screen_y < anthropic_y && anthropic_y < browser_y, msg=at)
    let said = fn(word : String) { t.words().filter(fn(x) { x.0 == word }).length() }
    // the agent's tab alone offers 关闭 here; 休眠 nowhere
    assert_eq(said("休眠"), 0, msg=at)
    assert_eq(said("关闭标签页"), 1, msg=at)
    assert_eq(t.squeeze_faults(), [], msg=at)
    // pressed: the tab looked at last, else the newest, opened at once (no question first)
    t.tap_text("打开浏览器")
    t.draw()
    assert_true(calls.iter().all(fn(c) { c.0 != "screen.openBrowser" }), msg=at)
  }
}

///|
test "the station goes back to an earlier release: picked from its menu, asked, then asked of the station" {
  for (w, platform) in page_cases {
    let calls : Array[Json] = []
    let t = setting_tester(Station("ws1/st1"), w, platform~, mode="settings-station-back", h=2400.0, over=fn(s) {
      { ..s, call: fn(name, params, done) {
        if name == "software.update" { calls.push(params) }
        (s.call)(name, params, done)
      } }
    })
    t.run_for(@ui.move_most_ms)
    let at = "\{w} platform \{platform}"
    assert_eq(t.audit(), [], msg=at)
    t.tap_text("退回旧版本")
    t.draw()
    presented_in(t)
    for v in ["0.1.1280", "0.1.1276", "0.1.1262"] {
      assert_true(t.find(v) is Some(_), msg="\{at}: \{v} offered")
    }
    assert_eq(t.audit(), [], msg="\{at}: its menu")
    t.tap_text("0.1.1276")
    t.draw()
    presented_in(t)
    assert_true(t.find("退回到 0.1.1276？") is Some(_), msg=at)
    assert_eq(calls.length(), 0, msg="\{at}: asked first")
    assert_eq(t.audit(), [], msg="\{at}: asked")
    t.click(Button, label="退回")
    t.draw()
    presented_in(t)
    assert_eq(calls.length(), 1, msg=at)
    assert_eq(text(Some(calls[0]), "id"), "station")
    assert_eq(text(Some(calls[0]), "to"), "0.1.1276")
    assert_eq(text(Some(calls[0]), "station"), "ws1/st1")
  }
}

///|
test "gone back, updating by itself held till a newer release says so under the version; none to go back to, no link" {
  for (w, platform) in page_cases {
    @sfbase.reset()
    reset()
    @settings.reset()
    @sffixture.fixture_reset()
    @sf.presenters_reset()
    @sf.set_words(@sfbase.fill)
    let src = @sffixture.fixture("settings")
    let held : Json = {
      "id": "station", "name": "Station", "installed": true, "updatable": true, "state": "idle", "shownText": "0.1.1290",
      "latest": "0.1.1300", "newer": true, "channel": "stable", "auto": false, "autoAfter": "0.1.1300",
    }
    let core = @sfbase.settings_core(src, rig_workspace)
    let t = station_part_tester(fn(p) {
      software_row_node(p, core, "ws1/st1", fn() { Some(held) }, true, fn() { false }, fn() { false }, fn() { true }, @sf.TipLayer::new(fn() { None }))
    }, w~, h=400.0, platform~)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("自动更新暂停到 0.1.1300 之后的版本") is Some(_), msg=at)
    assert_true(t.find("退回旧版本") is None, msg=at)
    assert_eq(t.audit(), [], msg=at)
  }
}

///|
test "an overridden station with autoWhen shows override status, hides auto switch, and restores official after confirm" {
  for (w, platform) in page_cases {
    let calls : Array[Json] = []
    let t = setting_tester(Station("ws1/st1"), w, platform~, mode="settings-station-override", h=2400.0, over=fn(s) {
      {
        ..s,
        call: fn(name, params, done) {
          if name == "software.update" { calls.push(params) }
          (s.call)(name, params, done)
        },
      }
    })
    t.run_for(@ui.move_most_ms)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("本地替换版（基于 0.1.1288）") is Some(_), msg="shownText: \{at}")
    assert_true(t.find("mm2 overview 扇出热修复") is Some(_), msg="overrideNote: \{at}")
    assert_true(t.find("将在 #8270、FB-123 发布后自动恢复官方版") is Some(_), msg="autoWhen: \{at}")
    assert_true(t.query(Switch, label="自动更新") is None, msg="auto switch hidden while overridden: \{at}")
    assert_true(t.query(Button, label="恢复官方版本") is Some(_), msg="restore button: \{at}")
    assert_eq(t.audit(), [], msg="audit \{at}: \{Repr(t.audit())}")
    assert_eq(t.squeeze_faults(), [], msg="squeeze \{at}: \{Repr(t.squeeze_faults())}")
    t.click(Button, label="恢复官方版本")
    t.draw()
    presented_in(t)
    assert_true(t.find("恢复为官方版本？") is Some(_), msg="confirm title: \{at}")
    assert_true(t.find("0.1.1300") is Some(_), msg="confirm note latest: \{at}")
    assert_eq(calls.length(), 0, msg="asked first: \{at}")
    assert_eq(t.audit(), [], msg="confirm audit: \{at}")
    t.click(Button, label="恢复官方版")
    t.draw()
    presented_in(t)
    assert_eq(calls.length(), 1, msg="restore called: \{at}")
    assert_eq(text(Some(calls[0]), "id"), "station", msg=at)
    assert_eq(text(Some(calls[0]), "station"), "ws1/st1", msg=at)
    // Also audit software_row_node with autoWhen directly at 1.0x and 1.3x font scales across widths
    @sfbase.reset()
    reset()
    @settings.reset()
    @sffixture.fixture_reset()
    @sf.presenters_reset()
    @sf.set_words(@sfbase.fill)
    let src = @sffixture.fixture("settings")
    let row_json : Json = {
      "id": "station", "name": "Station", "installed": true, "updatable": true, "state": "idle",
      "shownText": "本地替换版（基于 0.1.1288）", "latest": "0.1.1300", "overridden": true,
      "overrideBase": "0.1.1288", "overrideKind": "overlay", "overrideNote": "mm2 overview 扇出热修复",
      "autoWhen": ["#8270", "FB-123"], "channel": "stable", "auto": false,
    }
    let core = @sfbase.settings_core(src, rig_workspace)
    let rt = station_part_tester(fn(p) {
      software_row_node(p, core, "ws1/st1", fn() { Some(row_json) }, true, fn() { false }, fn() { false }, fn() { true }, @sf.TipLayer::new(fn() { None }))
    }, w~, h=400.0, platform~)
    for scale in [1.0, 1.3] {
      rt.set_font_scale(scale)
      rt.draw()
      assert_eq(rt.audit(), [], msg="row autoWhen audit \{at} scale \{scale}: \{Repr(rt.audit())}")
      assert_eq(rt.squeeze_faults(), [], msg="row autoWhen squeeze \{at} scale \{scale}: \{Repr(rt.squeeze_faults())}")
    }
  }
}

///|
test "an overridden station with autoHeld shows paused note and restore button cleanly across languages and font scales" {
  for (w, platform) in page_cases {
    @sfbase.reset()
    reset()
    @settings.reset()
    @sffixture.fixture_reset()
    @sf.presenters_reset()
    @sf.set_words(@sfbase.fill)
    let src = @sffixture.fixture("settings")
    let held : Json = {
      "id": "station", "name": "Station", "installed": true, "updatable": true, "state": "idle",
      "shownText": "本地替换版", "overridden": true, "autoHeld": true, "channel": "stable", "auto": false,
    }
    let core = @sfbase.settings_core(src, rig_workspace)
    let t = station_part_tester(fn(p) {
      software_row_node(p, core, "ws1/st1", fn() { Some(held) }, true, fn() { false }, fn() { false }, fn() { true }, @sf.TipLayer::new(fn() { None }))
    }, w~, h=400.0, platform~)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("本地替换中，已暂停自动更新") is Some(_), msg=at)
    assert_true(t.query(Switch, label="自动更新") is None, msg="auto switch hidden: \{at}")
    assert_true(t.query(Button, label="恢复官方版本") is Some(_), msg=at)
    for scale in [1.0, 1.3] {
      t.set_font_scale(scale)
      t.draw()
      assert_eq(t.audit(), [], msg="audit \{at} scale \{scale}: \{Repr(t.audit())}")
      assert_eq(t.squeeze_faults(), [], msg="squeeze \{at} scale \{scale}: \{Repr(t.squeeze_faults())}")
    }
    t.set_font_scale(1.0)
    @sf.set_language(Some("en"))
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("Local override active; auto-update paused") is Some(_), msg="en held: \{at}")
    assert_true(t.query(Button, label="Restore official") is Some(_), msg="en restore: \{at}")
    assert_eq(t.audit(), [], msg="en audit \{at}: \{Repr(t.audit())}")
    @sf.set_language(None)
  }
}

///|
/// Where the CPU's dial says its name (in its full words or its short ones), None where neither is drawn.
fn cpu_dial_at(t : @ui.Tester, full : String, short : String) -> (Double, Double)? {
  match t.find(full) {
    Some(at) => Some(at)
    None => t.find(short)
  }
}

///|
test "the CPU's dial pressed says how much is used, pressed again how much is idle, kept on this device" {
  for (w, platform) in page_cases {
    let asked : Array[Json] = []
    let t = setting_tester(
      Station("ws1/st1"),
      w,
      platform~,
      h=2400.0,
      over=fn(s) {
        {
          ..s,
          call: fn(name, params, done) {
            if name == "prefs.set" && field(Some(params), "cpuDial") is Some(_) {
              asked.push(params)
            }
            (s.call)(name, params, done)
          },
        }
      },
    )
    t.run_for(@ui.move_most_ms)
    let at = "\{w} \{platform}"
    guard cpu_dial_at(t, "CPU 空闲率", "CPU 空闲") is Some((x, y)) else { fail("no CPU dial: \{at}") }
    assert_true(t.find("72") is Some(_), msg="idle large: \{at}")
    t.tap(x, y)
    t.run_for(@ui.move_most_ms)
    assert_eq(asked.map(fn(p) { p.stringify() }), ["{\"cpuDial\":\"busy\"}"], msg=at)
    guard cpu_dial_at(t, "CPU 占用率", "CPU 占用") is Some((x, y)) else { fail("not turned to busy: \{at}") }
    assert_true(t.find("28") is Some(_), msg="busy large: \{at}")
    assert_true(t.find("72") is None, msg="idle no longer said: \{at}")
    assert_eq(t.squeeze_faults(), [], msg=at)
    t.tap(x, y)
    t.run_for(@ui.move_most_ms)
    assert_eq(asked.length(), 2, msg=at)
    assert_eq(asked[1].stringify(), "{\"cpuDial\":null}", msg=at)
    assert_true(cpu_dial_at(t, "CPU 空闲率", "CPU 空闲") is Some(_), msg="back to idle: \{at}")
    // (the memory's dial says what is left whatever the CPU's says)
    assert_true(t.find("可用内存") is Some(_), msg=at)
  }
}

///|
test "the stations' list says each machine's CPU the way this device has turned its dial: idle at first, busy as it is kept, idle again" {
  for (w, platform) in page_cases {
    let made : Ref[Source?] = Ref(None)
    let t = setting_tester(Stations, w, platform~, h=1200.0, over=fn(s) {
      made.val = Some(s)
      s
    })
    t.run_for(@ui.move_most_ms)
    let at = "\{w} \{platform}"
    let said = fn(words : String) { t.words().iter().any(fn(x) { x.0.contains(words) }) }
    // (the CPU's an icon on the row, what it says read out: its label)
    let cpu = fn(words : String) { t.semantics().iter().any(fn(n) { n.label == words && !n.hidden }) }
    assert_true(cpu("CPU 空闲 72%"), msg="idle at first: \{at}")
    let src = made.val.unwrap()
    (src.call)("prefs.set", { "cpuDial": "busy" }, @sfbase.answer_unread)
    t.run_for(@ui.move_most_ms)
    assert_true(cpu("CPU 占用 28%"), msg="busy: \{at} " + t.semantics().map(fn(n) { n.label }).join("|"))
    assert_true(!cpu("CPU 空闲 72%"), msg="idle no longer: \{at}")
    // (the memory's says what is left whichever way)
    assert_true(said("剩 5.8 G") || said("5.8G"), msg="memory: \{at}")
    (src.call)("prefs.set", { "cpuDial": Json::null() }, @sfbase.answer_unread)
    t.run_for(@ui.move_most_ms)
    assert_true(cpu("CPU 空闲 72%"), msg="idle again: \{at}")
    assert_eq(t.audit(), [], msg=at)
  }
}

///|
test "the backup history says each run of syncs that went well to one place once, by its newest" {
  let r = (id : String, target : String, status : String) => @settings.obj([
    ("id", Json::string(id)),
    ("kind", Json::string("sync")),
    ("target", Json::string(target)),
    ("status", Json::string(status)),
  ])
  let runs = copies_history_runs([
    r("1", "cedar", "ok"),
    r("2", "r2", "ok"),
    r("3", "cedar", "ok"),
    r("4", "cedar", "error"),
    r("5", "cedar", "ok"),
    r("6", "cedar", "ok"),
    r("7", "r2", "ok"),
  ])
  assert_eq(runs.map(x => text(Some(x), "id")), ["1", "2", "4", "5"])
}

///|
test "Settings MCP tab: lists stations, toggles shared/enabled, reconnects, deletes, and hides writes for non-managers" {
  for (w, platform) in page_cases {
    @sfbase.reset()
    reset()
    @settings.reset()
    @sffixture.fixture_reset()
    @sf.presenters_reset()
    @sf.set_words(@sfbase.fill)
    let calls : Array[(String, Json)] = []
    let base = @sffixture.fixture("settings")
    let src : Source = {
      ..base,
      call: fn(name, params, done) {
        if name.has_prefix("mcpServers.") {
          calls.push((name, params))
        }
        done(Ok(Json::null()))
      },
    }
    let servers : Array[Json] = [
      {
        "name": "github",
        "transport": "stdio",
        "enabled": true,
        "shared": true,
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-github"],
        "env": { "GITHUB_TOKEN": "ghp_1…9xyz" },
        "status": "ready",
        "toolCount": 12,
        "tools": ["create_issue"],
        "error": Json::null(),
      },
      {
        "name": "docs",
        "transport": "http",
        "enabled": true,
        "shared": false,
        "url": "https://docs.example.com/mcp",
        "headers": { "Authorization": "Beare…9xyz" },
        "status": "failed",
        "toolCount": 0,
        "tools": [],
        "error": "HTTP 502",
      },
    ]
    let core = @sfbase.settings_core(src, rig_workspace)
    let t = station_part_tester(fn(p) {
      mcp_station_card_node(p, core, "ws1/st1", fn() { "Willow" }, fn() { servers }, fn() { true }, fn() { true })
    }, w~, h=900.0, platform~)
    assert_true(t.find("Willow") is Some(_), msg="station title: \{w}")
    assert_true(t.find("github") is Some(_), msg="github server shown: \{w}")
    assert_true(t.find("docs") is Some(_), msg="docs server shown: \{w}")
    assert_true(t.find("HTTP 502") is Some(_), msg="error shown: \{w}")
    assert_true(t.find("跨站共享") is Some(_), msg="shared badge shown: \{w}")
    assert_true(t.find("添加 MCP 服务") is Some(_), msg="add button shown: \{w}")
    assert_eq(t.audit(), [], msg="manager audit: \{w}")

    // Click github row to open edit dialog, toggle shared off, and save
    t.click(Link, label="github")
    presented_in(t)
    assert_true(t.find("允许其他 Station 使用") is Some(_), msg="shared toggle in dialog: \{w}")
    t.click(Switch, label="允许其他 Station 使用")
    t.draw()
    t.click(Button, label="保存")
    presented_in(t)
    assert_eq(calls.length(), 1)
    assert_eq(calls[0].0, "mcpServers.save")
    assert_eq(field(field(field(Some(calls[0].1), "servers"), "github"), "shared"), None)

    // Re-open github dialog and reconnect
    t.click(Link, label="github")
    presented_in(t)
    t.click(Button, label="重新连接")
    presented_in(t)
    assert_eq(calls.length(), 2)
    assert_eq(calls[1].0, "mcpServers.reload")
    assert_eq(text(Some(calls[1].1), "name"), "github")

    // Re-open github dialog and delete via confirm dialog
    t.click(Link, label="github")
    presented_in(t)
    t.click(Button, label="删除")
    presented_in(t)
    assert_true(t.find("删除「github」？") is Some(_), msg="confirm shown: \{w}")
    let confirm_dels = t.all(Button, label="删除")
    let (cx, cy, cw, ch) = confirm_dels[confirm_dels.length() - 1].rect
    t.tap(cx + cw / 2.0, cy + ch / 2.0)
    presented_in(t)
    assert_eq(calls.length(), 3)
    assert_eq(calls[2].0, "mcpServers.save")
    assert_eq(field(field(Some(calls[2].1), "servers"), "github"), Some(Json::null()))

    // Non-manager view hides add button and makes rows non-editable
    let t_ro = station_part_tester(fn(p) {
      mcp_station_card_node(p, core, "ws1/st1", fn() { "Willow" }, fn() { servers }, fn() { false }, fn() { true })
    }, w~, h=900.0, platform~)
    assert_true(t_ro.find("github") is Some(_), msg="ro shows servers: \{w}")
    assert_true(t_ro.find("添加 MCP 服务") is None, msg="ro hides add: \{w}")
    assert_eq(t_ro.all(Link, label="github").length(), 0)
    assert_eq(t_ro.audit(), [], msg="ro audit: \{w}")
  }
}
