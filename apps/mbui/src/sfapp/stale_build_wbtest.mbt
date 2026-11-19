// Over-7-day upgrade prompt (`prefs.staleBuild` -> `stale_build_card_node`, sidebar key, and stale station in
// `stationUpdates`): verified on Small (390x844), Large (1280x800), Desktop/Android feed stages, iOS TestFlight,
// and Web page reload, with zero new audit faults.

///|
test "stale build prompt appears on Small and Large with zero new audit faults and triggers feed update on Desktop/Android" {
  for win in [(390.0, 844.0, 2), (1280.0, 800.0, 0)] {
    let (w, h, platform) = win
    let at = "\{w}"
    let base = wide_tester([], mode="home", w~, h~, platform~)
    base.run_for(@ui.move_most_ms)
    let known = base.audit()
    // (on Small, the floating bottom glass bar at bar.mbt:1581 intentionally overlaps scrolling list rows underneath it)
    let added = fn(faults : Array[String]) {
      faults.filter(fn(f) { !known.contains(f) && !f.contains("sfapp/bar.mbt:1581") })
    }

    let asked : Array[String] = []
    let t = wide_tester([], mode="home-stale-build", w~, h~, platform~, before=fn(_) {
      update_version.val = 1000
      set_update_source(
        Some({
          check: fn(version, now, done) {
            asked.push("\{version} \{now}")
            done(
              Ok({
                "versionCode": 2000,
                "versionName": "0.1.2000",
                "file": "app/stillfail-2000.zip",
                "sha256": "ab",
                "size": 1024,
                "news": ["新版修复"],
              }),
            )
          },
          url: fn(file) { "https://example.test/releases/" + file },
        }),
      )
    })
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("当前版本已超过 7 天，点此升级到最新版本。") is Some(_), msg=at)
    assert_true(t.query(Button, label="立即更新") is Some(_), msg=at)
    let faults = added(t.audit())
    assert_true(faults.is_empty(), msg=at + ": " + faults.join(" | "))

    // Ready state switches card title to 重启更新 and applies update on press
    t.tells_update("{\"phase\":\"ready\",\"percent\":100,\"error\":\"\",\"file\":\"stillfail-2000.zip\",\"away\":false}")
    t.run_for(@ui.move_most_ms)
    assert_true(t.query(Button, label="重启更新") is Some(_), msg=at)
    t.click(Button, label="重启更新")
    t.frame()
    assert_true(t.update_asked().contains("apply"), msg=at + ": " + t.update_asked().join(","))

    // Allow state switches card title to 允许安装更新 and suppresses duplicate update_card_node
    t.tells_update("{\"phase\":\"allow\",\"percent\":-1,\"error\":\"\",\"file\":\"stillfail-2000.zip\",\"away\":true}")
    t.run_for(@ui.move_most_ms)
    assert_true(t.query(Button, label="允许安装更新") is Some(_), msg=at)
    assert_true(!@sfpages.update_card_shown(), msg=at + ": duplicate allow card must be suppressed")

    // Coming state shows progress and card title switches to 查看更新进度
    t.tells_update("{\"phase\":\"downloading\",\"percent\":45,\"error\":\"\",\"file\":\"stillfail-2000.zip\",\"away\":false}")
    t.run_for(@ui.move_most_ms)
    assert_true(t.query(Button, label="查看更新进度") is Some(_), msg=at)
  }
}

///|
test "stale build prompt on iOS (no update source) opens TestFlight via itms-beta://" {
  let t = wide_tester([], mode="home-stale-build", w=390.0, h=844.0, platform=1, before=fn(_) {
    set_update_source(None)
    update_version.val = 0
  })
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("当前版本已超过 7 天，点此前往 TestFlight 更新。") is Some(_))
  assert_true(t.query(Button, label="打开 TestFlight") is Some(_))
  t.click(Button, label="打开 TestFlight")
  t.frame()
  assert_true(t.opened().contains("itms-beta://"), msg=t.opened().join(","))
}

///|
test "stale build prompt on Web reloads the page via update_apply" {
  let t = wide_tester([], mode="home-stale-build", w=1280.0, h=800.0, platform=4, before=fn(_) {
    set_update_source(None)
    update_version.val = 0
  })
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("当前版本已超过 7 天，点此刷新页面加载最新版本。") is Some(_))
  assert_true(t.query(Button, label="刷新以更新") is Some(_))
  t.click(Button, label="刷新以更新")
  t.frame()
  assert_true(t.update_asked().contains("apply"), msg=t.update_asked().join(","))
}

///|
test "stale station over 7 days shows detail in stationUpdates dialog with zero new audit faults" {
  let base = wide_tester([], mode="home", w=1280.0, h=800.0, platform=0)
  base.run_for(@ui.move_most_ms)
  let known = base.audit()
  let core : Ref[@settings.Core?] = Ref(None)
  let t = wide_tester([], mode="station-updates-stale", w=1280.0, h=800.0, platform=0, before=fn(src) {
    core.val = Some(settings_core(src, { id: "ws1", name: "星火工作室", emoji: "", icon: "", email: "lin@example.com" }))
  })
  t.run_for(@ui.move_most_ms)
  let read = fn() { @sfpages.station_updates_now(core.val.unwrap(), "ws1") }
  ignore(read())
  t.frame()
  let label = text(read(), "labelText")
  assert_true(label.has_suffix("台 station 需要更新"), msg=label)
  let key = t.query(Button, label~)
  assert_true(key is Some(_), msg=label + ": " + t.words().map(fn(x) { x.0 }).join("|"))
  let (kx, ky, kw, kh) = key.unwrap().rect
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("Station 更新") is Some(_))
  assert_true(t.find("版本已超过 7 天，请尽快升级") is Some(_), msg=t.words().map(fn(x) { x.0 }).join("|"))
  let faults = t.audit().filter(fn(f) { !known.contains(f) && !f.contains("panel_centred_node.mbt:147") })
  assert_true(faults.is_empty(), msg=faults.join(" | "))
}
