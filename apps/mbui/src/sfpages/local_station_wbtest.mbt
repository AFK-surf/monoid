// 本机 Station (local_station.mbt) alone, at each width, with a finger and with a mouse: as the system says it, its
// card with its facts in lines as the room has them, stopped from its menu; none here, 添加这台 Mac where the app adds
// one (a Mac's, Windows', Linux's host), a note alone elsewhere.

///|
/// A service of this machine's running in 星火工作室 as Willow, as the host says it.
let local_running : String =
  #|{"data":"~/.stillfail","runner":"service","version":"0.1.4600","service":{"kind":"launchd","name":"fail.still.station"},"workspace":{"id":"ws1","name":"星火工作室","stationName":"Willow","removed":false}}

///|
test "本机 Station, at each width and with either hand: as the system says it (a service running in a workspace), its facts in its card, stopped from its menu" {
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(LocalStation, w, platform~, host=fn(h) { h.set_app_said("local_station", local_running) })
    let at = "\{w} platform \{platform}"
    for words in ["本机 Station", "Willow", "运行中", "单独安装（launchd）", "0.1.4600", "在 星火工作室", "~/.stillfail"] {
      assert_true(t.find(words) is Some(_), msg="\{at}: \{words}")
    }
    // (its facts going on in lines where the room ends: none cut, none past the card)
    assert_eq(t.squeeze_faults(), [], msg=at)
    // stopped from its card's menu (the card's)
    t.click(Button, label="更多操作")
    t.frame()
    // (its menu in, a sheet's or a menu's)
    t.run_for(@ui.move_most_ms)
    let (sx, sy) = t.find_last("停止").unwrap()
    t.tap(sx, sy)
    t.frame()
    assert_eq(t.app_told("local_station_act"), ["stop"], msg=at)
  }
}

///|
test "本机 Station still.fail's desktop app ran (in a workspace, no service, stopped): 启动 runs the installer without a token" {
  for case in page_cases {
    let (w, platform) = case
    // (a Mac's host: the app looks after the station here)
    if platform != 0 {
      continue
    }
    let t = setting_tester(LocalStation, w, platform~, host=fn(h) { h.set_app_said("local_station", (
      #|{"data":"~/.stillfail","runner":"none","workspace":{"id":"ws1","name":"星火工作室","stationName":"MacBook","removed":false}}
      ),
    ) })
    let at = "\{w}"
    assert_true(t.find("已停止") is Some(_), msg=at)
    // (nothing runs it: no app said to)
    assert_true(t.find("由 still.fail app 运行") is None, msg=at)
    t.click(Button, label="启动")
    t.frame()
    let acts = t.app_told("local_station_act")
    assert_eq(acts.length(), 1, msg=at)
    assert_true(acts[0].has_prefix("update {"), msg="\{at}: \{acts[0]}")
    assert_true(!acts[0].contains("\"token\""), msg="\{at}: \{acts[0]}")
  }
}

///|
test "本机 Station with data in no workspace and no service: nothing to start it with" {
  let t = setting_tester(LocalStation, 1280.0, platform=0, host=fn(h) { h.set_app_said("local_station", (
    #|{"data":"~/.stillfail","runner":"none"}
    ),
  ) })
  assert_true(t.find("已停止") is Some(_))
  assert_true(t.query(Button, label="启动") is None)
}

///|
test "本机 Station with none here: 添加这台 Mac where the app adds one, the note alone where it does not" {
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(LocalStation, w, platform~, host=fn(h) { h.set_app_said("local_station", "") })
    let at = "\{w} platform \{platform}"
    assert_true(t.find("本机没有单独安装的 station") is Some(_), msg=at)
    // (a Mac's host adds one; a phone's has none to add)
    assert_eq(t.query(Button, label="添加这台 Mac") is Some(_), platform == 0, msg=at)
  }
}

///|
test "本机 Station made once: what the host says asked again every few seconds from when it is made, not before" {
  let t = setting_tester(LocalStation, 1280.0, platform=0, host=fn(h) { h.set_app_said("local_station", "") })
  assert_true(t.find("本机没有单独安装的 station") is Some(_))
  // (the station here started on its own: said by the host, shown once the page asks it again, at that moment)
  t.set_app_said("local_station", local_running)
  t.draw()
  assert_true(t.find("Willow") is None)
  t.run_for(@settings.local_read_ms)
  assert_true(t.find("Willow") is Some(_))
  assert_true(t.find("运行中") is Some(_))
}

///|
test "本机 Station with existing data unattached or removed offers 添加这台 Mac" {
  let cases : Array[(String, Json)] = [
    ("unattached", Json::null()),
    ("removed", { "id": "ws1", "name": "星火工作室", "station": "st1", "stationName": "Willow", "removed": true }),
  ]
  for one in cases {
    let (label, ws) = one
    let t = setting_tester(LocalStation, 1280.0, platform=0, host=fn(h) {
      h.set_app_said("local_station", (
        { "data": "/Users/test/.stillfail", "runner": "none", "installed": true, "workspace": ws } : Json
      ).stringify())
    })
    assert_true(t.query(Button, label="添加这台 Mac") is Some(_), msg=label)
  }
}

///|
test "本机 Station taken away from its menu, at each width and with either hand: 卸载本机 Station asked first, its data named; 卸载 tells the host" {
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(LocalStation, w, platform~, host=fn(h) { h.set_app_said("local_station", local_running) })
    let at = "\{w} platform \{platform}"
    t.click(Button, label="更多操作")
    t.frame()
    t.run_for(@ui.move_most_ms)
    // (only where the app looks after the station here: a Mac's host; a phone's has none to take away)
    if platform != 0 {
      assert_true(t.find_last("卸载本机 Station") is None, msg=at)
      continue
    }
    let (x, y) = t.find_last("卸载本机 Station").unwrap()
    t.tap(x, y)
    t.frame()
    t.run_for(@ui.move_most_ms)
    // asked first: nothing told yet, what goes and what stays said
    assert_eq(t.app_told("local_station_act"), [], msg=at)
    assert_true(t.find("将停止运行并移除开机自启服务与程序文件；本地对话、记忆和密钥数据仍保留在 ~/.stillfail。") is Some(_), msg=at)
    assert_eq(t.squeeze_faults(), [], msg=at)
    assert_eq(t.audit(), [], msg=at)
    t.click(Button, label="卸载")
    t.frame()
    assert_eq(t.app_told("local_station_act"), ["uninstall"], msg=at)
  }
}

///|
test "本机 Station's 卸载本机 Station only for one with a release or a service of its own" {
  let cases : Array[(String, String, Bool)] = [
    ("a service", local_running, true),
    ("a release, stopped", "{\"data\":\"~/.stillfail\",\"runner\":\"none\",\"installed\":true}", true),
    ("started by hand from a release", "{\"data\":\"~/.stillfail\",\"runner\":\"other\",\"installed\":true}", true),
    // (its data alone: nothing here to take away)
    ("data alone", "{\"data\":\"~/.stillfail\",\"runner\":\"none\",\"workspace\":{\"id\":\"ws1\",\"removed\":false}}", false),
    ("taken away already", "{\"data\":\"~/.stillfail\",\"runner\":\"none\",\"uninstalled\":true,\"workspace\":{\"id\":\"ws1\",\"removed\":false}}", false),
  ]
  for one in cases {
    let (why, said, offered) = one
    let t = setting_tester(LocalStation, 1280.0, platform=0, host=fn(h) { h.set_app_said("local_station", said) })
    t.click(Button, label="更多操作")
    t.frame()
    t.run_for(@ui.move_most_ms)
    assert_eq(t.find_last("卸载本机 Station") is Some(_), offered, msg=why)
  }
}

///|
test "本机 Station being taken away, then taken away: 正在卸载 while the host does it, nothing pressable; 已卸载 after, its data's facts kept" {
  let t = setting_tester(LocalStation, 1280.0, platform=0, host=fn(h) { h.set_app_said("local_station", (
    #|{"data":"~/.stillfail","runner":"service","doing":"uninstall","installed":true,"service":{"kind":"launchd","name":"fail.still.station"},"workspace":{"id":"ws1","name":"星火工作室","stationName":"Willow","removed":false}}
    ),
  ) })
  assert_true(t.find("正在卸载") is Some(_))
  t.click(Button, label="更多操作")
  t.frame()
  t.run_for(@ui.move_most_ms)
  // (its menu's every act held while it is done: pressed, nothing told)
  let (x, y) = t.find_last("卸载本机 Station").unwrap()
  t.tap(x, y)
  t.frame()
  assert_eq(t.app_told("local_station_act"), [])
  t.key_told(@ui.key_escape, 0, t.time())
  t.run_for(@ui.move_most_ms)
  t.set_app_said("local_station", (
    #|{"data":"~/.stillfail","runner":"none","uninstalled":true,"workspace":{"id":"ws1","name":"星火工作室","stationName":"Willow","removed":false}}
    ),
  )
  t.run_for(@settings.local_read_ms)
  for words in ["Willow", "已卸载", "在 星火工作室", "~/.stillfail"] {
    assert_true(t.find(words) is Some(_), msg=words)
  }
  assert_true(t.find("正在卸载") is None)
  assert_true(t.find("已停止") is None)
  assert_eq(t.audit(), [])
}

///|
/// A service of this machine's running in 星火工作室 as Willow, its data moved to an external disk, its command one
/// that moves it.
let local_moved : String =
  #|{"data":"~/.stillfail","at":"/Volumes/外接盘/stillfail","moves":true,"runner":"service","version":"0.1.4600","installed":true,"service":{"kind":"launchd","name":"fail.still.station"},"workspace":{"id":"ws1","name":"星火工作室","stationName":"Willow","removed":false}}

///|
test "本机 Station's data moved from its menu, at each width and with either hand: 更改存储位置… asked first, saying what it does; 选择文件夹 tells the host" {
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(LocalStation, w, platform~, host=fn(h) { h.set_app_said("local_station", local_moved) })
    let at = "\{w} platform \{platform}"
    // where its data is now
    assert_true(t.find("数据在 /Volumes/外接盘/stillfail") is Some(_), msg=at)
    t.click(Button, label="更多操作")
    t.frame()
    t.run_for(@ui.move_most_ms)
    // (only where the app looks after the station here: a Mac's host; a phone's has none to move)
    if platform != 0 {
      assert_true(t.find_last("更改存储位置…") is None, msg=at)
      continue
    }
    let (x, y) = t.find_last("更改存储位置…").unwrap()
    t.tap(x, y)
    t.frame()
    t.run_for(@ui.move_most_ms)
    assert_eq(t.app_told("local_station_act"), [], msg=at)
    assert_true(t.find_last("选择文件夹") is Some(_), msg=at)
    assert_eq(t.squeeze_faults(), [], msg=at)
    assert_eq(t.audit(), [], msg=at)
    t.click(Button, label="选择文件夹")
    t.frame()
    assert_eq(t.app_told("local_station_act"), ["move"], msg=at)
  }
}

///|
test "本机 Station's 更改存储位置… only where its command moves its data" {
  let t = setting_tester(LocalStation, 1280.0, platform=0, host=fn(h) { h.set_app_said("local_station", local_running) })
  t.click(Button, label="更多操作")
  t.frame()
  t.run_for(@ui.move_most_ms)
  assert_true(t.find_last("在 Finder 中显示数据") is Some(_))
  assert_true(t.find_last("更改存储位置…") is None)
}

///|
test "本机 Station moving its data, its disk not connected, a move that did not go: how far, 磁盘未连接 and what to do, why it stayed" {
  let t = setting_tester(LocalStation, 1280.0, platform=0, host=fn(h) { h.set_app_said("local_station", (
    #|{"data":"~/.stillfail","moves":true,"runner":"none","doing":"move","percent":42,"installed":true,"service":{"kind":"launchd","name":"fail.still.station"},"workspace":{"id":"ws1","name":"星火工作室","stationName":"Willow","removed":false}}
    ),
  ) })
  assert_true(t.find("正在移动数据 · 42%") is Some(_))
  t.set_app_said("local_station", (
    #|{"data":"~/.stillfail","at":"/Volumes/外接盘/stillfail","away":true,"runner":"none","service":{"kind":"launchd","name":"fail.still.station"}}
    ),
  )
  t.run_for(@settings.local_read_ms)
  assert_true(t.find("磁盘未连接") is Some(_))
  assert_true(t.find("接上 /Volumes/外接盘/stillfail 所在的磁盘后会自动启动") is Some(_))
  // (which workspace it is in is on that disk: not said to be none)
  assert_true(t.find("未加入任何 workspace") is None)
  // (its data is there, only away: nothing added beside it, nothing to start till the disk is back)
  assert_true(t.query(Button, label="添加这台 Mac") is None)
  assert_true(t.query(Button, label="启动") is None)
  assert_eq(t.audit(), [])
  t.set_app_said("local_station", (
    #|{"data":"~/.stillfail","moves":true,"runner":"service","failed":"move.7","installed":true,"service":{"kind":"launchd","name":"fail.still.station"},"workspace":{"id":"ws1","name":"星火工作室","stationName":"Willow","removed":false}}
    ),
  )
  t.run_for(@settings.local_read_ms)
  assert_true(t.find("station 无法从新位置启动，数据已移回原处；可以打开日志查看原因") is Some(_))
  t.set_app_said("local_station", (
    #|{"data":"~/.stillfail","moves":true,"runner":"service","failed":"move:sh: not found","installed":true,"service":{"kind":"launchd","name":"fail.still.station"},"workspace":{"id":"ws1","name":"星火工作室","stationName":"Willow","removed":false}}
    ),
  )
  t.run_for(@settings.local_read_ms)
  assert_true(t.find("移动没有完成，数据仍在原处：sh: not found") is Some(_))
}

///|
test "a station's security code read off its id as the core reads it (lock-form.ts `shortCodeOf`, station/test/cli-lock-code.test.ts), nothing for what is no id" {
  assert_eq(station_short_code("0000000000000000000000000000000000000000000000000000000000000000"), "3EL-E55")
  assert_eq(station_short_code("a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7"), "5XC-L6N")
  assert_eq(station_short_code("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"), "D4A-K4W")
  assert_eq(station_short_code(""), "")
  assert_eq(station_short_code("0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef"), "")
  assert_eq(station_short_code("0123456789abcdef"), "")
}

///|
test "本机 Station in a workspace says its security code in its facts, to check a rig by in safe mode (FB-45); removed from it, none" {
  let in_ws : String =
    #|{"data":"~/.stillfail","runner":"service","version":"0.1.4600","service":{"kind":"launchd","name":"fail.still.station"},"workspace":{"id":"ws1","name":"星火工作室","stationName":"Willow","station":"0000000000000000000000000000000000000000000000000000000000000000","removed":false}}
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(LocalStation, w, platform~, host=fn(h) { h.set_app_said("local_station", in_ws) })
    let at = "\{w} platform \{platform}"
    assert_true(t.find("安全码：3EL-E55") is Some(_), msg=at)
    assert_eq(t.squeeze_faults(), [], msg=at)
  }
  let removed : String =
    #|{"data":"~/.stillfail","runner":"none","workspace":{"id":"ws1","name":"星火工作室","stationName":"Willow","station":"0000000000000000000000000000000000000000000000000000000000000000","removed":true}}
  let t = setting_tester(LocalStation, 1280.0, platform=0, host=fn(h) { h.set_app_said("local_station", removed) })
  assert_true(t.find("安全码") is None)
}
