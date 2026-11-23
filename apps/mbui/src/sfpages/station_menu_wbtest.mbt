// A station's ⋯ menu (station_menu_items), including while it is offline during an update. A menu's None is drawn as
// a line, never as an absent item: what a station does not offer now (restart and 改成只跑任务 while it is offline, 迁移
// and 迁走 where they are not offered) is left out, so the one line between what is done with it and what takes it away
// is the only one, with no empty lines beside it.

///|
test "a station's menu leaves out what it does not offer, one line before what takes it away" {
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
    (false, true, false, ["edit", "line", "trash"]),
    (true, true, false, ["edit", "power", "boxes", "line", "trash"]),
    (true, false, false, ["edit", "power", "line", "trash"]),
    (true, true, true, ["edit", "power", "boxes", "line", "trash"]),
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
    let icons = entries.map(fn(entry) { match entry { Some(item) => item.icon; None => "line" } })
    assert_eq(icons, expected, msg="online=\{online} mine=\{mine} joined=\{joined}")
    assert_true(entries.last().unwrap().unwrap().danger)
  }
}
