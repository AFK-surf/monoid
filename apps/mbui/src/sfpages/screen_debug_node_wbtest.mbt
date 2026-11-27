// 日志 (screen_debug_node.mbt) as it stood with an old body (recorded off @sf.panel's on main, 2026-11-09), made of
// nodes in the panel its presenter gives it: on 小屏 a sheet from the foot, keyboard and mouse beside 控制中心's button;
// App, 设备 (as the device says and as it was set here) and 日志 each, every word and each thing to press where it was;
// but what is under a field (打开链接's, 推送通知's, 定位's), 4 lower for each over it (2026-11-17: a field's lit ground
// and the row's under it apart, rule 1: screen_debug_node.mbt's debug_field_under).

///|
/// The rig on a simulator that debugs an app, the app last started again known; 日志 opened (`open`), App in it, then
/// each of what is pinned, `check` told which and its words and what is said.
fn logs_pinned(r : ScreenRig, open : () -> Unit, check : (String) -> Unit raise) -> Unit raise {
  simulator_live(r)
  let d = r.ui().logs
  d.last_app.set(Some(("fail.still.demo", "Demo")))
  d.tab.set(0)
  open()
  logs_rest(r)
  check("app")
  d.tab.set(debug_tab_device)
  logs_rest(r)
  check("device")
  d.enrolled.set(Some(true))
  d.tidy_bar.set(true)
  d.acted.set("已完成")
  logs_rest(r)
  check("device2")
  d.acted.set("")
  d.lines.set([
    { at: "13:23:11", level: "Error", app: "Demo", words: "something failed here" },
    { at: "13:23:12", level: "Info", app: "Demo", words: "and then this came" },
  ])
  d.tab.set(debug_tab_logs)
  logs_rest(r)
  check("logs")
}

///|
/// What moves gone its declared length: a sheet to its rest, a panel in (move_most_ms), a segmented choice's thumb
/// (a cover's slide, @ui.cover_slide_ms).
fn logs_rest(r : ScreenRig) -> Unit {
  r.t.run_for(@sf.later_ms)
  to_sheet_rest(r.t)
  r.t.run_for(@ui.move_most_ms)
  r.t.run_for(@ui.cover_slide_ms)
}

///|
test "日志 on 小屏: a sheet from the foot, App, 设备 and 日志 each where its old body had them" {
  let r = screen_rig()
  let want : Map[String, (Array[(String, Double, Double, Double, Double)], Array[(String, String, Double, Double, Double, Double)])] = {
    "app": (logs_phone_app_words, logs_phone_app_said),
    "device": (logs_phone_device_words, logs_phone_device_said),
    "device2": (logs_phone_device2_words, logs_phone_device2_said),
    "logs": (logs_phone_logs_words, logs_phone_logs_said),
  }
  logs_pinned(r, fn() { r.tap_label(tr("web-pages.screen.debug.logs")) }, fn(at) raise {
    let (words, said) = want.get(at).unwrap()
    let off = center_words_off(r.t, words) + center_said_off(r.t, said)
    if !off.is_empty() {
      println("OFF \{at}: " + off.join(" | "))
    }
    assert_eq((at, off), (at, []))
  })
  r.ui().logs.tab.set(0)
  logs_rest(r)
  screen_done(r.t)
}

///|
test "日志 with keyboard and mouse: beside 控制中心's button, App, 设备 and 日志 each where its old body had them" {
  let r = screen_rig(w=1280.0, h=800.0, platform=0)
  // open the collapsible right debug drawer so this pinned snapshot covers both the drawer and the logs popover
  r.ui().logs.shown_set = true
  r.ui().logs.shown.set(true)
  let want : Map[String, (Array[(String, Double, Double, Double, Double)], Array[(String, String, Double, Double, Double, Double)])] = {
    "app": (logs_wide_app_words, logs_wide_app_said),
    "device": (logs_wide_device_words, logs_wide_device_said),
    "device2": (logs_wide_device2_words, logs_wide_device2_said),
    "logs": (logs_wide_logs_words, logs_wide_logs_said),
  }
  logs_pinned(r, fn() {
    r.ui().asked_panel.set("logs")
    r.t.draw()
  }, fn(at) raise {
    let (words, said) = want.get(at).unwrap()
    let off = center_words_off(r.t, words) + center_said_off(r.t, said)
    if !off.is_empty() {
      println("OFF \{at}: " + off.join(" | "))
    }
    assert_eq((at, off), (at, []))
  })
  r.ui().logs.tab.set(0)
  r.t.resize(390.0, 844.0)
  r.t.run_for(@sf.toast_ms)
  screen_done(r.t)
}

///|
test "日志's choices: 设备's set as chosen, told once; the tab shared with the pane beside the device" {
  let r = screen_rig()
  simulator_live(r)
  let d = r.ui().logs
  d.tab.set(debug_tab_device)
  r.tap_label(tr("web-pages.screen.debug.logs"))
  logs_rest(r)
  // 状态栏 made tidy
  r.t.tap_text(tr("web-pages.screen.debug.statusTidy"))
  logs_rest(r)
  assert_true(d.tidy_bar.get())
  assert_eq(r.told("screen.statusBar").length(), 1)
  assert_eq(flag(Some(r.told("screen.statusBar")[0]), "tidy"), true)
  // 已录入: its two then shown
  assert_true(r.t.find(tr("web-pages.screen.debug.bioMatch")) is None)
  r.t.tap_text(tr("web-pages.screen.debug.enrolled"))
  logs_rest(r)
  assert_eq(d.enrolled.get(), Some(true))
  assert_eq(text(Some(r.told("screen.biometrics")[0]), "what"), "enrol")
  assert_true(r.t.find(tr("web-pages.screen.debug.bioMatch")) is Some(_))
  // 深色 set
  r.t.tap_text(tr("web-pages.screen.debug.dark"))
  logs_rest(r)
  let set = r.told("screen.setSetting")
  assert_eq(set.length(), 1)
  assert_eq((text(Some(set[0]), "name"), text(Some(set[0]), "value")), ("appearance", "dark"))
  // App chosen: what it holds
  r.t.tap_text(tr("web-pages.screen.debug.app"))
  logs_rest(r)
  assert_eq(d.tab.get(), 0)
  assert_true(r.t.find(tr("web-pages.screen.debug.openUrlGo")) is Some(_))
  screen_done(r.t)
}

///|
test "复制日志: 已复制 for diag_said_ms from each press, a press while it shows starting it again" {
  let r = screen_rig()
  simulator_live(r)
  let d = r.ui().logs
  d.lines.set([{ at: "13:23:11", level: "Info", app: "Demo", words: "something came" }])
  d.tab.set(debug_tab_logs)
  r.tap_label(tr("web-pages.screen.debug.logs"))
  logs_rest(r)
  let copy = tr("web-pages.screen.debug.logsCopy")
  let copied = tr("web-pages.screen.stat.copied")
  r.t.tap_text(copy)
  r.t.draw()
  assert_true(r.t.find(copied) is Some(_))
  assert_true(r.t.find(copy) is None)
  // pressed again half way: its end from this press
  r.t.run_for(diag_said_ms / 2.0)
  assert_true(r.t.find(copied) is Some(_))
  r.t.tap_text(copied)
  r.t.draw()
  r.t.run_for(diag_said_ms * 3.0 / 4.0)
  assert_true(r.t.find(copied) is Some(_))
  // and past that end (the second press's moment and diag_said_ms on), 复制日志 again
  r.t.run_for(diag_said_ms / 2.0)
  r.t.draw()
  assert_true(r.t.find(copy) is Some(_))
  assert_true(r.t.find(copied) is None)
  d.tab.set(0)
  logs_rest(r)
  screen_done(r.t)
}

///|
test "日志's 卸载 App opens its list beside its row, with keyboard and mouse" {
  let r = screen_rig(w=1280.0, h=800.0, platform=0)
  simulator_live(r)
  let d = r.ui().logs
  d.tab.set(0)
  r.ui().asked_panel.set("logs")
  r.t.draw()
  logs_rest(r)
  let (rx, ry) = center_said_at(r.t, "Button", tr("web-pages.screen.debug.uninstall")).unwrap()
  r.t.tap(rx, ry)
  logs_rest(r)
  assert_eq(r.told("screen.apps").length(), 1)
  // (its panel by the row, not by 控制中心's button)
  let dialogs = r.t.semantics().filter(fn(s) { !s.hidden && "\{s.role}" == "Dialog" && s.label == tr("web-pages.screen.debug.uninstall") })
  assert_eq(dialogs.length(), 1)
  let (_, dy, _, dh) = dialogs[0].rect
  assert_true((dy <= ry && ry <= dy + dh) || (dy - ry).abs() < 80.0, msg="\{Repr(dialogs[0].rect)} \{ry}")
  d.tab.set(0)
  r.t.resize(390.0, 844.0)
  r.t.run_for(@sf.toast_ms)
  screen_done(r.t)
}

///|
// kept across runs: the recording, never written (full-width docked at tall=0.82 on 390x844 phone)
let logs_phone_app_words : Array[(String, Double, Double, Double, Double)] = [
  ("日志", 179.0, 181.0, 32.0, 24.0),
  ("App", 64.0, 230.0, 21.0, 19.5),
  ("日志", 181.0, 230.0, 28.0, 19.5),
  ("设备", 301.5, 230.0, 28.0, 19.5),
  ("重启 App", 58.0, 273.0, 268.0, 20.0),
  ("Demo", 336.0, 274.0, 26.0, 18.0),
  ("重启 App：Demo", 58.0, 317.0, 280.0, 20.0),
  ("录屏", 58.0, 361.0, 304.0, 20.0),
  ("打开链接", 28.0, 403.0, 334.0, 18.0),
  ("https://", 28.0, 430.0, 334.0, 22.0),
  ("在设备里打开", 58.0, 475.0, 304.0, 20.0),
  ("推送通知", 28.0, 517.0, 334.0, 18.0),
  ("通知内容", 28.0, 544.0, 334.0, 22.0),
  ("发给应用", 58.0, 589.0, 280.0, 20.0),
  ("卸载 App", 58.0, 637.0, 280.0, 20.0),
]

///|
// kept across runs: the recording, never written
let logs_phone_app_said : Array[(String, String, Double, Double, Double, Double)] = [
  ("Radio", "App", 14.0, 225.0, 120.5, 30.0),
  ("Radio", "日志", 134.5, 225.0, 120.5, 30.0),
  ("Radio", "设备", 255.5, 225.0, 120.5, 30.0),
  ("Button", "重启 App Demo", 12.0, 261.0, 366.0, 44.0),
  ("Button", "重启 App：Demo", 12.0, 305.0, 366.0, 44.0),
  ("Button", "录屏", 12.0, 349.0, 366.0, 44.0),
  ("TextField", "https://", 28.0, 430.0, 334.0, 22.0),
  ("Button", "在设备里打开", 12.0, 463.0, 366.0, 44.0),
  ("TextField", "通知内容", 28.0, 544.0, 334.0, 22.0),
  ("Button", "发给应用", 12.0, 577.0, 366.0, 44.0),
  ("Button", "卸载 App", 12.0, 625.0, 366.0, 44.0),
]

///|
// kept across runs: the recording, never written
let logs_phone_device_words : Array[(String, Double, Double, Double, Double)] = [
  ("日志", 179.0, 181.0, 32.0, 24.0),
  ("App", 64.0, 230.0, 21.0, 19.5),
  ("日志", 181.0, 230.0, 28.0, 19.5),
  ("设备", 301.5, 230.0, 28.0, 19.5),
  ("外观", 28.0, 267.0, 334.0, 18.0),
  ("浅色", 90.5, 294.0, 28.0, 19.5),
  ("深色", 271.5, 294.0, 28.0, 19.5),
  ("文字大小", 28.0, 331.0, 334.0, 18.0),
  ("小", 52.5, 358.0, 14.0, 19.5),
  ("默认", 136.0, 358.0, 28.0, 19.5),
  ("大", 233.5, 358.0, 14.0, 19.5),
  ("特大", 317.0, 358.0, 28.0, 19.5),
  ("定位", 28.0, 395.0, 334.0, 18.0),
  ("纬度, 经度", 28.0, 422.0, 334.0, 22.0),
  ("把设备移到这里", 58.0, 467.0, 304.0, 20.0),
  ("清除定位", 58.0, 511.0, 304.0, 20.0),
  ("状态栏", 28.0, 553.0, 334.0, 18.0),
  ("真实", 90.5, 580.0, 28.0, 19.5),
  ("整洁（9:41）", 243.5, 580.0, 84.0, 19.5),
  ("面容 / 指纹", 28.0, 617.0, 334.0, 18.0),
  ("未录入", 83.5, 644.0, 42.0, 19.5),
  ("已录入", 264.5, 644.0, 42.0, 19.5),
  ("音量加", 58.0, 687.0, 304.0, 20.0),
  ("音量减", 58.0, 731.0, 304.0, 20.0),
  ("模拟内存警告", 58.0, 775.0, 304.0, 20.0),
]

///|
// kept across runs: the recording, never written
let logs_phone_device_said : Array[(String, String, Double, Double, Double, Double)] = [
  ("Radio", "App", 14.0, 225.0, 120.5, 30.0),
  ("Radio", "日志", 134.5, 225.0, 120.5, 30.0),
  ("Radio", "设备", 255.5, 225.0, 120.5, 30.0),
  ("Radio", "浅色", 14.0, 289.0, 181.0, 30.0),
  ("Radio", "深色", 195.0, 289.0, 181.0, 30.0),
  ("Radio", "小", 14.0, 353.0, 90.5, 30.0),
  ("Radio", "默认", 104.5, 353.0, 90.5, 30.0),
  ("Radio", "大", 195.0, 353.0, 90.5, 30.0),
  ("Radio", "特大", 285.5, 353.0, 90.5, 30.0),
  ("TextField", "纬度, 经度", 28.0, 422.0, 334.0, 22.0),
  ("Button", "把设备移到这里", 12.0, 455.0, 366.0, 44.0),
  ("Button", "清除定位", 12.0, 499.0, 366.0, 44.0),
  ("Radio", "真实", 14.0, 575.0, 181.0, 30.0),
  ("Radio", "整洁（9:41）", 195.0, 575.0, 181.0, 30.0),
  ("Radio", "未录入", 14.0, 639.0, 181.0, 30.0),
  ("Radio", "已录入", 195.0, 639.0, 181.0, 30.0),
  ("Button", "音量加", 12.0, 675.0, 366.0, 44.0),
  ("Button", "音量减", 12.0, 719.0, 366.0, 44.0),
  ("Button", "模拟内存警告", 12.0, 763.0, 366.0, 44.0),
]

///|
// kept across runs: the recording, never written
let logs_phone_device2_words : Array[(String, Double, Double, Double, Double)] = [
  ("日志", 179.0, 181.0, 32.0, 24.0),
  ("App", 64.0, 230.0, 21.0, 19.5),
  ("日志", 181.0, 230.0, 28.0, 19.5),
  ("设备", 301.5, 230.0, 28.0, 19.5),
  ("外观", 28.0, 267.0, 334.0, 18.0),
  ("浅色", 90.5, 294.0, 28.0, 19.5),
  ("深色", 271.5, 294.0, 28.0, 19.5),
  ("文字大小", 28.0, 331.0, 334.0, 18.0),
  ("小", 52.5, 358.0, 14.0, 19.5),
  ("默认", 136.0, 358.0, 28.0, 19.5),
  ("大", 233.5, 358.0, 14.0, 19.5),
  ("特大", 317.0, 358.0, 28.0, 19.5),
  ("定位", 28.0, 395.0, 334.0, 18.0),
  ("纬度, 经度", 28.0, 422.0, 334.0, 22.0),
  ("把设备移到这里", 58.0, 467.0, 304.0, 20.0),
  ("清除定位", 58.0, 511.0, 304.0, 20.0),
  ("状态栏", 28.0, 553.0, 334.0, 18.0),
  ("真实", 90.5, 580.0, 28.0, 19.5),
  ("整洁（9:41）", 243.5, 580.0, 84.0, 19.5),
  ("面容 / 指纹", 28.0, 617.0, 334.0, 18.0),
  ("未录入", 83.5, 644.0, 42.0, 19.5),
  ("已录入", 264.5, 644.0, 42.0, 19.5),
  ("匹配", 58.0, 683.0, 304.0, 20.0),
  ("不匹配", 58.0, 727.0, 304.0, 20.0),
  ("音量加", 58.0, 775.0, 304.0, 20.0),
  ("音量减", 58.0, 819.0, 304.0, 20.0),
  ("模拟内存警告", 58.0, 863.0, 304.0, 20.0),
  ("已完成", 28.0, 899.0, 334.0, 18.0),
]

///|
// kept across runs: the recording, never written
let logs_phone_device2_said : Array[(String, String, Double, Double, Double, Double)] = [
  ("Radio", "App", 14.0, 225.0, 120.5, 30.0),
  ("Radio", "日志", 134.5, 225.0, 120.5, 30.0),
  ("Radio", "设备", 255.5, 225.0, 120.5, 30.0),
  ("Radio", "浅色", 14.0, 289.0, 181.0, 30.0),
  ("Radio", "深色", 195.0, 289.0, 181.0, 30.0),
  ("Radio", "小", 14.0, 353.0, 90.5, 30.0),
  ("Radio", "默认", 104.5, 353.0, 90.5, 30.0),
  ("Radio", "大", 195.0, 353.0, 90.5, 30.0),
  ("Radio", "特大", 285.5, 353.0, 90.5, 30.0),
  ("TextField", "纬度, 经度", 28.0, 422.0, 334.0, 22.0),
  ("Button", "把设备移到这里", 12.0, 455.0, 366.0, 44.0),
  ("Button", "清除定位", 12.0, 499.0, 366.0, 44.0),
  ("Radio", "真实", 14.0, 575.0, 181.0, 30.0),
  ("Radio", "整洁（9:41）", 195.0, 575.0, 181.0, 30.0),
  ("Radio", "未录入", 14.0, 639.0, 181.0, 30.0),
  ("Radio", "已录入", 195.0, 639.0, 181.0, 30.0),
  ("Button", "匹配", 12.0, 671.0, 366.0, 44.0),
  ("Button", "不匹配", 12.0, 715.0, 366.0, 44.0),
  ("Button", "音量加", 12.0, 763.0, 366.0, 44.0),
  ("Button", "音量减", 12.0, 807.0, 366.0, 44.0),
  ("Button", "模拟内存警告", 12.0, 851.0, 366.0, 44.0),
]

///|
// kept across runs: the recording, never written
let logs_phone_logs_words : Array[(String, Double, Double, Double, Double)] = [
  ("日志", 179.0, 181.0, 32.0, 24.0),
  ("App", 64.0, 230.0, 21.0, 19.5),
  ("日志", 181.0, 230.0, 28.0, 19.5),
  ("设备", 301.5, 230.0, 28.0, 19.5),
  ("复制日志", 169.0, 263.0, 52.0, 20.0),
  ("13:23:12 Demo  and then this came", 12.0, 289.0, 366.0, 16.0),
  ("13:23:11 Demo  something failed here", 12.0, 309.0, 366.0, 16.0),
]

///|
// kept across runs: the recording, never written
let logs_phone_logs_said : Array[(String, String, Double, Double, Double, Double)] = [
  ("Radio", "App", 14.0, 225.0, 120.5, 30.0),
  ("Radio", "日志", 134.5, 225.0, 120.5, 30.0),
  ("Radio", "设备", 255.5, 225.0, 120.5, 30.0),
  ("Button", "复制日志", 12.0, 261.0, 366.0, 24.0),
]

///|
// kept across runs: the recording, never written
let logs_wide_app_words : Array[(String, Double, Double, Double, Double)] = [
  ("App", 990.5, 66.0, 19.5, 18.0),
  ("日志", 1039.0, 66.0, 26.0, 18.0),
  ("设备", 1091.0, 66.0, 26.0, 18.0),
  ("日志", 874.0, 56.0, 376.0, 20.0),
  ("App", 888.5, 97.0, 19.5, 18.0),
  ("日志", 937.0, 97.0, 26.0, 18.0),
  ("设备", 989.0, 97.0, 26.0, 18.0),
  ("重启 App", 916.0, 136.0, 288.0, 20.0),
  ("Demo", 1214.0, 137.5, 24.0, 17.0),
  ("重启 App：Demo", 916.0, 172.0, 298.0, 20.0),
  ("录屏", 916.0, 208.0, 322.0, 20.0),
  ("打开链接", 886.0, 246.0, 352.0, 18.0),
  ("https://", 886.0, 273.0, 352.0, 22.0),
  ("在设备里打开", 916.0, 314.0, 322.0, 20.0),
  ("推送通知", 886.0, 352.0, 352.0, 18.0),
  ("通知内容", 886.0, 379.0, 352.0, 22.0),
  ("发给应用", 916.0, 420.0, 298.0, 20.0),
  ("卸载 App", 916.0, 460.0, 298.0, 20.0),
  ("重启 App", 1018.0, 109.0, 200.0, 20.0),
  ("Demo", 1228.0, 110.5, 24.0, 17.0),
  ("重启 App：Demo", 1018.0, 145.0, 210.0, 20.0),
  ("打开链接", 988.0, 187.0, 264.0, 18.0),
  ("https://", 988.0, 214.0, 264.0, 22.0),
  ("在设备里打开", 1018.0, 255.0, 234.0, 20.0),
  ("推送通知", 988.0, 297.0, 264.0, 18.0),
  ("通知内容", 988.0, 324.0, 264.0, 22.0),
  ("发给应用", 1018.0, 365.0, 210.0, 20.0),
  ("卸载 App", 1018.0, 409.0, 210.0, 20.0),
]

///|
// kept across runs: the recording, never written
let logs_wide_app_said : Array[(String, String, Double, Double, Double, Double)] = [
  ("Radio", "App", 873.0, 91.0, 50.0, 30.0),
  ("Radio", "日志", 925.0, 91.0, 50.0, 30.0),
  ("Radio", "设备", 977.0, 91.0, 50.0, 30.0),
  ("Button", "重启 App Demo", 870.0, 128.0, 384.0, 36.0),
  ("Button", "重启 App：Demo", 870.0, 164.0, 384.0, 36.0),
  ("TextField", "https://", 886.0, 273.0, 352.0, 22.0),
  ("Button", "在设备里打开", 870.0, 306.0, 384.0, 36.0),
  ("TextField", "通知内容", 886.0, 379.0, 352.0, 22.0),
  ("Button", "发给应用", 870.0, 412.0, 384.0, 36.0),
  ("Button", "卸载 App", 870.0, 452.0, 384.0, 36.0),
]

///|
// kept across runs: the recording, never written
let logs_wide_device_words : Array[(String, Double, Double, Double, Double)] = [
  ("App", 990.5, 66.0, 19.5, 18.0),
  ("日志", 1039.0, 66.0, 26.0, 18.0),
  ("设备", 1091.0, 66.0, 26.0, 18.0),
  ("日志", 874.0, 56.0, 376.0, 20.0),
  ("App", 888.5, 97.0, 19.5, 18.0),
  ("日志", 937.0, 97.0, 26.0, 18.0),
  ("设备", 989.0, 97.0, 26.0, 18.0),
  ("外观", 886.0, 134.0, 352.0, 18.0),
  ("浅色", 885.0, 163.0, 26.0, 18.0),
  ("深色", 937.0, 163.0, 26.0, 18.0),
  ("文字大小", 886.0, 200.0, 352.0, 18.0),
  ("小", 891.5, 229.0, 13.0, 18.0),
  ("默认", 937.0, 229.0, 26.0, 18.0),
  ("大", 995.5, 229.0, 13.0, 18.0),
  ("特大", 1041.0, 229.0, 26.0, 18.0),
  ("定位", 886.0, 266.0, 352.0, 18.0),
  ("纬度, 经度", 886.0, 293.0, 352.0, 22.0),
  ("把设备移到这里", 916.0, 334.0, 322.0, 20.0),
  ("清除定位", 916.0, 370.0, 322.0, 20.0),
  ("状态栏", 886.0, 408.0, 352.0, 18.0),
  ("真实", 911.0, 437.0, 26.0, 18.0),
  ("整洁（9:41）", 989.0, 437.0, 78.0, 18.0),
  ("面容 / 指纹", 886.0, 474.0, 352.0, 18.0),
  ("未录入", 885.0, 503.0, 39.0, 18.0),
  ("已录入", 950.0, 503.0, 39.0, 18.0),
  ("音量加", 916.0, 542.0, 322.0, 20.0),
  ("音量减", 916.0, 578.0, 322.0, 20.0),
  ("模拟内存警告", 916.0, 614.0, 322.0, 20.0),
  ("外观", 988.0, 107.0, 264.0, 18.0),
  ("浅色", 987.0, 136.0, 26.0, 18.0),
  ("深色", 1039.0, 136.0, 26.0, 18.0),
  ("文字大小", 988.0, 177.0, 264.0, 18.0),
  ("小", 993.5, 206.0, 13.0, 18.0),
  ("默认", 1039.0, 206.0, 26.0, 18.0),
  ("大", 1097.5, 206.0, 13.0, 18.0),
  ("特大", 1143.0, 206.0, 26.0, 18.0),
  ("定位", 988.0, 247.0, 264.0, 18.0),
  ("纬度, 经度", 988.0, 274.0, 264.0, 22.0),
  ("把设备移到这里", 1018.0, 315.0, 234.0, 20.0),
  ("清除定位", 1018.0, 351.0, 234.0, 20.0),
  ("状态栏", 988.0, 393.0, 264.0, 18.0),
  ("真实", 1013.0, 422.0, 26.0, 18.0),
  ("整洁（9:41）", 1091.0, 422.0, 78.0, 18.0),
  ("面容 / 指纹", 988.0, 463.0, 264.0, 18.0),
  ("未录入", 987.0, 492.0, 39.0, 18.0),
  ("已录入", 1052.0, 492.0, 39.0, 18.0),
  ("模拟内存警告", 1018.0, 535.0, 234.0, 20.0),
]

///|
// kept across runs: the recording, never written
let logs_wide_device_said : Array[(String, String, Double, Double, Double, Double)] = [
  ("Radio", "App", 873.0, 91.0, 50.0, 30.0),
  ("Radio", "日志", 925.0, 91.0, 50.0, 30.0),
  ("Radio", "设备", 977.0, 91.0, 50.0, 30.0),
  ("Radio", "浅色", 873.0, 157.0, 50.0, 30.0),
  ("Radio", "深色", 925.0, 157.0, 50.0, 30.0),
  ("Radio", "小", 873.0, 223.0, 50.0, 30.0),
  ("Radio", "默认", 925.0, 223.0, 50.0, 30.0),
  ("Radio", "大", 977.0, 223.0, 50.0, 30.0),
  ("Radio", "特大", 1029.0, 223.0, 50.0, 30.0),
  ("TextField", "纬度, 经度", 886.0, 293.0, 352.0, 22.0),
  ("Button", "把设备移到这里", 870.0, 326.0, 384.0, 36.0),
  ("Button", "清除定位", 870.0, 362.0, 384.0, 36.0),
  ("Radio", "真实", 873.0, 431.0, 102.0, 30.0),
  ("Radio", "整洁（9:41）", 977.0, 431.0, 102.0, 30.0),
  ("Radio", "未录入", 873.0, 497.0, 63.0, 30.0),
  ("Radio", "已录入", 938.0, 497.0, 63.0, 30.0),
  ("Button", "模拟内存警告", 870.0, 606.0, 384.0, 36.0),
]

///|
// kept across runs: the recording, never written
let logs_wide_device2_words : Array[(String, Double, Double, Double, Double)] = [
  ("App", 990.5, 66.0, 19.5, 18.0),
  ("日志", 1039.0, 66.0, 26.0, 18.0),
  ("设备", 1091.0, 66.0, 26.0, 18.0),
  ("已完成", 988.0, 770.0, 264.0, 18.0),
  ("日志", 874.0, 56.0, 376.0, 20.0),
  ("App", 888.5, 97.0, 19.5, 18.0),
  ("日志", 937.0, 97.0, 26.0, 18.0),
  ("设备", 989.0, 97.0, 26.0, 18.0),
  ("外观", 886.0, 134.0, 352.0, 18.0),
  ("浅色", 885.0, 163.0, 26.0, 18.0),
  ("深色", 937.0, 163.0, 26.0, 18.0),
  ("文字大小", 886.0, 200.0, 352.0, 18.0),
  ("小", 891.5, 229.0, 13.0, 18.0),
  ("默认", 937.0, 229.0, 26.0, 18.0),
  ("大", 995.5, 229.0, 13.0, 18.0),
  ("特大", 1041.0, 229.0, 26.0, 18.0),
  ("定位", 886.0, 266.0, 352.0, 18.0),
  ("纬度, 经度", 886.0, 293.0, 352.0, 22.0),
  ("把设备移到这里", 916.0, 334.0, 322.0, 20.0),
  ("清除定位", 916.0, 370.0, 322.0, 20.0),
  ("状态栏", 886.0, 408.0, 352.0, 18.0),
  ("真实", 911.0, 437.0, 26.0, 18.0),
  ("整洁（9:41）", 989.0, 437.0, 78.0, 18.0),
  ("面容 / 指纹", 886.0, 474.0, 352.0, 18.0),
  ("未录入", 885.0, 503.0, 39.0, 18.0),
  ("已录入", 950.0, 503.0, 39.0, 18.0),
  ("匹配", 916.0, 538.0, 322.0, 20.0),
  ("不匹配", 916.0, 574.0, 322.0, 20.0),
  ("音量加", 916.0, 614.0, 322.0, 20.0),
  ("音量减", 916.0, 650.0, 322.0, 20.0),
  ("模拟内存警告", 916.0, 686.0, 322.0, 20.0),
  ("已完成", 886.0, 718.0, 352.0, 18.0),
  ("外观", 988.0, 107.0, 264.0, 18.0),
  ("浅色", 987.0, 136.0, 26.0, 18.0),
  ("深色", 1039.0, 136.0, 26.0, 18.0),
  ("文字大小", 988.0, 177.0, 264.0, 18.0),
  ("小", 993.5, 206.0, 13.0, 18.0),
  ("默认", 1039.0, 206.0, 26.0, 18.0),
  ("大", 1097.5, 206.0, 13.0, 18.0),
  ("特大", 1143.0, 206.0, 26.0, 18.0),
  ("定位", 988.0, 247.0, 264.0, 18.0),
  ("纬度, 经度", 988.0, 274.0, 264.0, 22.0),
  ("把设备移到这里", 1018.0, 315.0, 234.0, 20.0),
  ("清除定位", 1018.0, 351.0, 234.0, 20.0),
  ("状态栏", 988.0, 393.0, 264.0, 18.0),
  ("真实", 1013.0, 422.0, 26.0, 18.0),
  ("整洁（9:41）", 1091.0, 422.0, 78.0, 18.0),
  ("面容 / 指纹", 988.0, 463.0, 264.0, 18.0),
  ("未录入", 987.0, 492.0, 39.0, 18.0),
  ("已录入", 1052.0, 492.0, 39.0, 18.0),
  ("匹配", 1018.0, 527.0, 234.0, 20.0),
  ("不匹配", 1018.0, 563.0, 234.0, 20.0),
  ("模拟内存警告", 1018.0, 607.0, 234.0, 20.0),
]

///|
// kept across runs: the recording, never written
let logs_wide_device2_said : Array[(String, String, Double, Double, Double, Double)] = [
  ("Radio", "App", 873.0, 91.0, 50.0, 30.0),
  ("Radio", "日志", 925.0, 91.0, 50.0, 30.0),
  ("Radio", "设备", 977.0, 91.0, 50.0, 30.0),
  ("Radio", "浅色", 873.0, 157.0, 50.0, 30.0),
  ("Radio", "深色", 925.0, 157.0, 50.0, 30.0),
  ("Radio", "小", 873.0, 223.0, 50.0, 30.0),
  ("Radio", "默认", 925.0, 223.0, 50.0, 30.0),
  ("Radio", "大", 977.0, 223.0, 50.0, 30.0),
  ("Radio", "特大", 1029.0, 223.0, 50.0, 30.0),
  ("TextField", "纬度, 经度", 886.0, 293.0, 352.0, 22.0),
  ("Button", "把设备移到这里", 870.0, 326.0, 384.0, 36.0),
  ("Button", "清除定位", 870.0, 362.0, 384.0, 36.0),
  ("Radio", "真实", 873.0, 431.0, 102.0, 30.0),
  ("Radio", "整洁（9:41）", 977.0, 431.0, 102.0, 30.0),
  ("Radio", "未录入", 873.0, 497.0, 63.0, 30.0),
  ("Radio", "已录入", 938.0, 497.0, 63.0, 30.0),
  ("Button", "匹配", 870.0, 530.0, 384.0, 36.0),
  ("Button", "不匹配", 870.0, 566.0, 384.0, 36.0),
  ("Button", "模拟内存警告", 870.0, 678.0, 384.0, 36.0),
]

///|
// kept across runs: the recording, never written
let logs_wide_logs_words : Array[(String, Double, Double, Double, Double)] = [
  ("App", 990.5, 66.0, 19.5, 18.0),
  ("日志", 1039.0, 66.0, 26.0, 18.0),
  ("设备", 1091.0, 66.0, 26.0, 18.0),
  ("复制日志", 1210.0, 65.0, 48.0, 20.0),
  ("日志", 874.0, 56.0, 376.0, 20.0),
  ("App", 888.5, 97.0, 19.5, 18.0),
  ("日志", 937.0, 97.0, 26.0, 18.0),
  ("设备", 989.0, 97.0, 26.0, 18.0),
  ("复制日志", 1038.0, 130.0, 48.0, 20.0),
  ("13:23:12 Demo  and then this came", 870.0, 156.0, 384.0, 16.0),
  ("13:23:11 Demo  something failed here", 870.0, 176.0, 384.0, 16.0),
  ("13:23:12 Demo  and then this came", 972.0, 101.0, 296.0, 16.0),
  ("13:23:11 Demo  something failed here", 972.0, 117.0, 296.0, 16.0),
]

///|
// kept across runs: the recording, never written
let logs_wide_logs_said : Array[(String, String, Double, Double, Double, Double)] = [
  ("Radio", "App", 873.0, 91.0, 50.0, 30.0),
  ("Radio", "日志", 925.0, 91.0, 50.0, 30.0),
  ("Radio", "设备", 977.0, 91.0, 50.0, 30.0),
  ("Button", "复制日志", 870.0, 128.0, 384.0, 24.0),
]

///|
test "debug_lines_node clears timeline when parked and preserves chained after-answer + d.asking dedup on wake" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let log_calls : Array[(Result[Json, Json]) -> Unit] = []
  let base = @sffixture.fixture("settings")
  @sfbase.workspace_owner_set("ws-1", "u1")
  let src : Source = {
    ..base,
    call: fn(name, _params, done) {
      if name == "screen.logs" {
        log_calls.push(done)
      } else {
        done(Ok(Json::null()))
      }
    },
  }
  let s = screen_sess(src, "ws-1/st-1", "sim:1")
  let u = screen_ui(screen_key("ws-1/st-1", "sim:1"))
  let d = u.logs
  let active = @signals.signal(true)
  let logs_root : Ref[@view.View?] = Ref(None)
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.pick_kept(at_once=true, fn() { active.get() }, fn(slot, on) {
        if on {
          logs_root.val = Some(slot)
          debug_lines_node(slot, s, d)
        }
      })
    },
    w=800.0,
    h=600.0,
    platform=0,
    keeps_sources=true,
  )
  t.draw()
  let lv = logs_root.val.unwrap()
  // First ask fired immediately on mount, waiting for answer -> 0 timers yet while in-flight.
  assert_eq(log_calls.length(), 1)
  assert_true(d.asking)
  // Answer arrives -> schedules next poll via at_moment_active.
  (log_calls[0])(Ok({ "lines": Json::array([]) }))
  t.draw()
  assert_false(d.asking)
  assert_true(t.subtree_timeline_count(lv) > 0, msg="active debug_lines_node should schedule next poll after answer")
  // Park -> timeline entries cleared to 0, advancing time does NOT fire extra asks.
  active.set(false)
  t.draw()
  assert_eq(t.subtree_timeline_count(lv), 0, msg="parked debug_lines_node must have 0 timeline entries")
  t.run_for(debug_logs_ms * 3.0)
  assert_eq(log_calls.length(), 1, msg="parked debug_lines_node must not poll while parked")
  // Wake while d.asking is true (another pane already asking) -> dedups without firing duplicate call.
  d.asking = true
  active.set(true)
  t.draw()
  t.run_for(debug_logs_ms)
  assert_eq(log_calls.length(), 1, msg="d.asking dedup must prevent duplicate screen.logs call")
  // Once d.asking clears, next scheduled tick fires chained ask.
  d.asking = false
  t.run_for(debug_logs_ms)
  assert_eq(log_calls.length(), 2, msg="debug_lines_node should resume chained polling once d.asking clears")
  @ui.run_let_go()
}
