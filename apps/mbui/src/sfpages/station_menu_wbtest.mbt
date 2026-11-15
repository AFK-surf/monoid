// A station's menu on each screen, including while it is offline during an update.

///|
test "a station's menu omits unavailable actions without drawing separators" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let src = @sffixture.fixture("settings")
  let core = @sfbase.settings_core(src, rig_workspace)
  let here = @settings.here_of(core, rig_workspace.id, rig_workspace.name)
  // During an update the station can be offline. Also cover the online owner, someone else's station and a joined one.
  for (online, mine, joined, expected) in [
    (false, true, false, ["edit", "trash"]),
    (true, true, false, ["edit", "power", "boxes", "trash"]),
    (true, false, false, ["edit", "power", "trash"]),
    (true, true, true, ["edit", "power", "trash"]),
  ] {
    let station : Json = {
      "station": "ws1/st1",
      "id": "st1",
      "name": "Willow",
      "online": Json::boolean(online),
      "mine": Json::boolean(mine),
      "joined": Json::boolean(joined),
    }
    let entries = station_menu_items(core, here, Some(station))
    let icons = entries.map(fn(entry) { match entry { Some(item) => item.icon; None => "separator" } })
    assert_eq(icons, expected, msg="online=\{online} mine=\{mine} joined=\{joined}")
    assert_true(entries.last().unwrap().unwrap().danger)
  }
}

///|
test "an offline station's menu opens with its remaining actions on every screen" {
  for (w, platform) in page_cases {
    let t = setting_tester(Station("ws1/st2"), w, platform~, mode="settings-station-offline")
    t.run_for(@ui.move_most_ms)
    t.click(Button, label="更多")
    t.run_for(@ui.move_most_ms)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("重命名") is Some(_), msg=at)
    assert_true(t.find("从 workspace 移除") is Some(_), msg=at)
    assert_true(t.find("重启") is None, msg=at)
    assert_eq(t.audit(), [], msg=at)
  }
}
