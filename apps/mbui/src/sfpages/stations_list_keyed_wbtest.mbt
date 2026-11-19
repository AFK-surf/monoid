// The stations' list (stations_list.mbt) keeps the workspace's rigs and devices by their keys once (View::keyed_by):
// one of them changed tells its own card alone, so what a change runs is the same however many the workspace has
// (a phone's Place stations, 2026-11-19: 70.6 ms of a frame, every card looking its own up in the whole list).

///|
/// The list over a made-up core of `n` rigs and `n` devices, each its own; then the device `which` and the rig
/// `which` renamed in turn. What the tree's bindings ran in the frame of each change, and the names shown after.
fn sl_keyed_run(n : Int, which : Int) -> (Int, Int, Bool) raise {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let rig = fn(i : Int, name : String) -> Json { { "id": Json::string("r\{i}"), "name": Json::string(name) } }
  let device = fn(i : Int, name : String) -> Json {
    { "station": "ws1/st1", "id": Json::string("d\{i}"), "name": Json::string(name), "kind": "phone" }
  }
  let rigs = @signals.signal(Array::makei(n, fn(i) { rig(i, "机器 \{i}") }))
  let devices = @signals.signal(Array::makei(n, fn(i) { device(i, "设备 \{i}") }))
  let src = @sfbase.made_source(topic=fn(name, _) {
    match name {
      "stations" => Some([])
      "workspace" => Some({ "role": "owner", "rigs": Json::array(rigs.get()) })
      "rigs" => Some({ "rigs": Json::array(rigs.get()) })
      "devices" => Some({ "devices": Json::array(devices.get()) })
      _ => None
    }
  })
  let core = @sfbase.settings_core(src, rig_workspace)
  let here = fn() { @settings.here_of(core, rig_workspace.id, rig_workspace.name) }
  let t = station_part_tester(
    fn(p) { stations_list_node(p, core, here, on_back=fn() {  }, frame=fn() { @sf.no_frame }) },
    w=390.0,
    h=8000.0,
    platform=2,
  )
  assert_true(t.find("设备 \{which}") is Some(_), msg="\{n}: its devices shown")
  assert_true(t.find("机器 \{which}") is Some(_), msg="\{n}: its rigs shown")
  let ran = fn(change : () -> Unit) {
    t.tree_frames_from_now()
    change()
    t.draw()
    t.tree_frames().fold(init=0, fn(s, f) { s + f.bindings })
  }
  let device_ran = ran(fn() {
    let all = devices.untracked().copy()
    all[which] = device(which, "新设备")
    devices.set(all)
  })
  let rig_ran = ran(fn() {
    let all = rigs.untracked().copy()
    all[which] = rig(which, "新机器")
    rigs.set(all)
  })
  let shown = t.find("新设备") is Some(_) &&
    t.find("新机器") is Some(_) &&
    t.find("设备 \{which}") is None &&
    t.find("设备 \{(which + 1) % n}") is Some(_)
  (device_ran, rig_ran, shown)
}

///|
test "stations_list: one device or rig of many changed runs its own card's bindings alone, as many as of a few" {
  let (few_device, few_rig, few_shown) = sl_keyed_run(3, 1)
  let (many_device, many_rig, many_shown) = sl_keyed_run(30, 17)
  assert_true(few_shown && many_shown, msg="the changed one's new name shown, the others as they were")
  assert_true(few_device > 0 && few_rig > 0, msg="the changed card told: \{few_device}, \{few_rig}")
  // (the other cards' bindings woken none: the same count at thirty as at three)
  assert_eq((many_device, many_rig), (few_device, few_rig))
}
