// Pure unit tests for rigs_mode: task ownership keys, disk thresholds, port ordering, grant wording,
// form validation, JSON serialization, request status messages, and Windows elevation scripts.

///|
test "a task's owner, made and read back" {
  let key = owner_of("01WS", "bb", "CHAT/1.0:x")
  assert_eq(key, "remote:01WS:bb:CHAT/1.0:x")
  assert_eq(owned(key), Some(("01WS", "bb", "CHAT/1.0:x")))
  assert_eq(owned("remote:a:b:"), Some(("a", "b", "")))
  assert_eq(owned("remote:a"), None)
  assert_eq(owned("local:a:b:c"), None)
}

///|
test "the disk's marks and how often it is looked at" {
  let gib = 1073741824.0
  assert_eq(disk_tier(10.0 * gib, 1000.0 * gib), "low")
  // (a disk of less than 200 GiB is low under a tenth of it, not under 20 GiB)
  assert_eq(disk_low(100.0 * gib), 10.0 * gib)
  assert_eq(disk_low(1000.0 * gib), 20.0 * gib)
  assert_eq(disk_tier(15.0 * gib, 100.0 * gib), "soft")
  assert_eq(disk_tier(9.0 * gib, 100.0 * gib), "low")
  assert_eq(disk_tier(25.0 * gib, 100.0 * gib), "soft")
  assert_eq(disk_tier(50.0 * gib, 1000.0 * gib), "soft")
  assert_eq(disk_tier(200.0 * gib, 1000.0 * gib), "ok")
  assert_eq(disk_soft(100.0 * gib), 30.0 * gib)
  assert_eq(disk_every("ok"), 300000.0)
  assert_eq(disk_every("low"), 30000.0)
}

///|
test "the door's ports, in order" {
  assert_eq(ports_to_try(Some(9), Some(1), 4750, true), [9])
  assert_eq(ports_to_try(None, Some(4751), 4750, true), [4751, 4750, 0])
  assert_eq(ports_to_try(None, Some(4750), 4750, true), [4750, 0])
  assert_eq(ports_to_try(None, None, 4750, false), [0])
}

///|
test "how long a grant lasts, in an agent's words" {
  let t = (kind : String, seconds : Double) => Some(jobj([("kind", jstr(kind)), ("seconds", jnum(seconds))]))
  assert_eq(lasting(t("fixed", 7200.0)), "for 2 h")
  assert_eq(lasting(t("fixed", 600.0)), "for 10 min")
  assert_eq(lasting(t("fixed", 172800.0)), "for 2 d")
  assert_eq(
    lasting(t("idle", 5400.0)),
    "until this chat has used it for nothing for 90 min (a task of yours still running there is use)",
  )
}

///|
test "a timeout and a device as the forms take them" {
  let t = (kind : String, seconds : Double) => Some(jobj([("kind", jstr(kind)), ("seconds", jnum(seconds))]))
  assert_eq(timeout_refusal(t("idle", 60.0)), None)
  assert_true(timeout_refusal(t("idle", 90.0)) is Some(_))
  assert_true(timeout_refusal(t("fixed", 2592060.0)) is Some(_))
  assert_true(timeout_refusal(t("always", 600.0)) is Some(_))
  let d = (kind : String, target : String) => Some(
    jobj([("id", jstr("0123456789abcdef")), ("name", jstr("cam")), ("kind", jstr(kind)), ("target", jstr(target))]),
  )
  assert_eq(device_refusal(d("tcp", "10.0.0.2:554")), None)
  assert_eq(device_refusal(d("tcp", "[fe80::1]:80")), None)
  assert_eq(device_refusal(d("tcp", "host:65536")), Some("a tcp device's port is 1 to 65535"))
  assert_eq(device_refusal(d("tcp", "host:0")), Some("a tcp device's target is host:port"))
  assert_eq(device_refusal(d("serial", "COM3")), None)
  assert_eq(device_refusal(d("serial", "tty0")), Some("a serial device's target is its path (/dev/…) or COMn"))
  assert_eq(device_refusal(d("adb", "a b")), Some("target: what it is reached at, with no spaces"))
}

///|
test "JSON as JavaScript writes it: an object's integer-like keys first" {
  let v = jobj([("b", jnum(1.0)), ("10", jnum(2.0)), ("2", jnum(3.0)), ("a", Json::array([jnum(1.5)]))])
  assert_eq(stringify(v), "{\"2\":3,\"10\":2,\"b\":1,\"a\":[1.5]}")
  assert_eq(js_string_of(Some(Json::array([Json::null(), jnum(2.0), jstr("x")]))), ",2,x")
  assert_eq(js_string_of(Some(jobj([]))), "[object Object]")
  assert_eq(js_trim("\u{a0} x \u{feff}"), "x")
}

///|
test "paths as node's join, times as toISOString, ids as the station makes them" {
  assert_eq(path_join(["/d/", "run", "x.json"]), "/d/run/x.json")
  assert_eq(path_join(["/d", "../e", "./f"]), "/e/f")
  assert_eq(path_join(["a", "", "b"]), "a/b")
  assert_eq(iso(1800000000000.0), "2027-01-15T08:00:00.000Z")
  assert_eq(base36(1800000000000.0), "mywpiww0")
  assert_eq(request_id_of(1800000000000.0, "i"), "r_mywpiww0i")
  assert_eq(js_number(" 12 "), 12.0)
  assert_eq(js_number(""), 0.0)
  assert_eq(js_number("0x10"), 16.0)
  assert_true(js_number("x").is_nan())
}

///|
test "a request said to its agent, as it stands" {
  let r : RigRequest = Map([
    ("id", jstr("r1")),
    ("rigName", jstr("box")),
    ("owner", jstr("pat")),
    ("ownerEmail", jstr("")),
    ("timeout", jobj([("kind", jstr("fixed")), ("seconds", jnum(600.0))])),
    ("status", jstr("denied")),
  ])
  assert_eq(said(r), "Your request r1 for the tasks-only station box was refused.")
  r["why"] = jstr("所有者已拒绝")
  assert_eq(said(r), "Your request r1 for the tasks-only station box was refused (所有者已拒绝).")
  r["status"] = jstr("granted")
  r["delivered"] = jbool(true)
  assert_true(said(r).contains("was granted by pat (for 10 min)"))
}

///|
test "the scripts run elevated end as Windows reads them" {
  let apply = apply_script(
    run="/d/run",
    data="/d",
    task="it's",
    on=true,
    deadline=5.0,
    restart=false,
    runner="/d/run/w.exe",
  )
  assert_true(apply.has_prefix("\u{feff}"))
  assert_true(apply.has_suffix("}\r\n"))
  assert_true(apply.contains("Level 'it''s' 'Highest'"))
  assert_true(apply.contains("-gt 5) { exit 3 }"))
  assert_true(!apply.contains("Register-ScheduledTask"))
  let restart = restart_script(run="/d/run", data="/d", app="/d/app", task="t", on=false)
  assert_true(restart.contains("try { Level $task 'Highest' } catch {}\r\n  Keep $true"))
  assert_true(ask_script("/d/run/a.ps1", true).contains("-Verb RunAs"))
  assert_true(!ask_script("/d/run/a.ps1", false).contains("RunAs"))
}

///|
test "well_formed validates rig statement shapes and rejects malformed bounds" {
  let hex64 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  let sig = jobj([("key", jstr("k1")), ("sig", jstr("aabb"))])
  let base = [
    ("v", jnum(1.0)),
    ("sub", jstr("user-1")),
    ("ws", jstr("01WS")),
    ("rig", jstr(hex64)),
    ("at", jnum(1000.0)),
  ]
  let wrap = (fields : Array[(String, Json)]) => Some(jobj([("body", jobj(base + fields)), ("sig", sig)]))
  assert_true(well_formed("add", wrap([])))
  // (the workspace lock's entry a rig pins: an entry's hash, nothing else, rig-form.ts `AddBody`, FB-45)
  assert_true(well_formed("add", wrap([("lock", jstr(hex64))])))
  assert_true(!well_formed("add", wrap([("lock", jstr("ABC"))])))
  assert_true(!well_formed("add", wrap([("lock", Json::null())])))
  assert_true(well_formed("full", wrap([])))
  assert_true(!well_formed("unknown", wrap([])))
  assert_true(well_formed("revoke", wrap([("request", jstr("r_1"))])))
  assert_true(!well_formed("revoke", wrap([("request", jstr(""))])))
  assert_true(well_formed("settings", wrap([("seq", jnum(1.0)), ("open", jbool(true))])))
  assert_true(well_formed("settings", wrap([("seq", jnum(1.0)), ("open", jbool(false)), ("device", jstr("0123456789abcdef"))])))
  assert_true(!well_formed("settings", wrap([("seq", jnum(1.0)), ("open", jbool(false)), ("device", jstr("bad"))])))
  let grant_fields = [
    ("station", jstr(hex64)),
    ("session", jstr("CHAT/1.0")),
    ("chat", jstr("CHAT/1.0")),
    ("request", jstr("r_1")),
    ("title", jstr("test")),
    ("by", jstr("alice")),
    ("timeout", jobj([("kind", jstr("fixed")), ("seconds", jnum(600.0))])),
    ("exp", jnum(1600.0)),
  ]
  assert_true(well_formed("grant", wrap(grant_fields)))
  // exp must exceed at
  let bad_exp = [
    ("station", jstr(hex64)),
    ("session", jstr("CHAT/1.0")),
    ("chat", jstr("CHAT/1.0")),
    ("request", jstr("r_1")),
    ("title", jstr("test")),
    ("by", jstr("alice")),
    ("timeout", jobj([("kind", jstr("fixed")), ("seconds", jnum(600.0))])),
    ("exp", jnum(1000.0)),
  ]
  assert_true(!well_formed("grant", wrap(bad_exp)))
  // missing sig is rejected
  assert_true(!well_formed("add", Some(jobj([("body", jobj(base))]))))
}

///|
test "latest, device_id_ok, manages_station, elevation_on and safe_int edge cases" {
  assert_eq(latest(1000.0, Some(jobj([("kind", jstr("fixed")), ("seconds", jnum(300.0))]))), 1300.0)
  assert_eq(latest(1000.0, Some(jobj([("kind", jstr("idle")), ("seconds", jnum(300.0))]))), 1000.0 + timeout_max)
  assert_true(device_id_ok("0123456789abcdef"))
  assert_true(!device_id_ok("0123456789abcde"))
  assert_true(!device_id_ok("0123456789abcdeg"))
  assert_true(manages_station({ workspace: "ws", sub: "u1", role: "owner", email: None, name: None }))
  assert_true(manages_station({ workspace: "ws", sub: "u2", role: "admin", email: None, name: None }))
  assert_true(!manages_station({ workspace: "ws", sub: "u3", role: "member", email: None, name: None }))
  assert_true(elevation_on("windows"))
  assert_true(!elevation_on("darwin"))
  assert_true(!elevation_on("linux"))
  assert_true(safe_int(42.0))
  assert_true(!safe_int(42.5))
  assert_eq(mcp_port_file("/tmp/st"), "/tmp/st/run/mcp.json")
}

///|
test "said formats pending, undelivered, ended and device-scoped grant statuses" {
  let mk = (status : String) => {
    let r : RigRequest = Map([
      ("id", jstr("r2")),
      ("rigName", jstr("lab-mac")),
      ("owner", jstr("bob")),
      ("ownerEmail", jstr("bob@example.com")),
      ("timeout", jobj([("kind", jstr("idle")), ("seconds", jnum(3600.0))])),
      ("status", jstr(status)),
    ])
    r
  }
  assert_true(said(mk("pending")).contains("waits for its owner bob@example.com"))
  let undel = mk("granted")
  assert_true(said(undel).contains("not reached now"))
  let ended = mk("ended")
  ended["why"] = jstr("expired")
  assert_true(said(ended).contains("ended (expired)"))
  let dev = mk("granted")
  dev["device"] = jstr("0123456789abcdef")
  dev["deviceName"] = jstr("usb-cam")
  dev["delivered"] = jbool(true)
  assert_true(said(dev).contains("usb-cam"))
  assert_true(said(dev).contains("bob@example.com"))
}

///|
test "screen_service_ask_script and screen_service_parse_probe handle quoting, UAC and status JSON" {
  let inst = screen_service_ask_script("C:\\O'Brien\\stillfail-screen-svc.exe", true, Some("S-1-5-21-1-2-3-1001"), true)
  assert_true(inst.contains("C:\\O''Brien\\stillfail-screen-svc.exe"))
  assert_true(inst.contains("'install', '--user-sid', 'S-1-5-21-1-2-3-1001'"))
  assert_true(inst.contains("-Verb RunAs"))
  assert_true(inst.contains("NativeErrorCode -eq 1223) { exit 4 }"))
  let uninst = screen_service_ask_script("C:\\app\\stillfail-screen-svc.exe", false, None, false)
  assert_true(uninst.contains("@('uninstall')"))
  assert_true(!uninst.contains("-Verb RunAs"))
  let parsed = screen_service_parse_probe(
    "{\"elevated\":false,\"admin\":true,\"userSid\":\"S-1-5-21-1-2-3-1001\",\"binary\":\"C:\\\\app\\\\stillfail-screen-svc.exe\",\"status\":\"{\\\"installed\\\":true,\\\"running\\\":true,\\\"connected\\\":true}\"}",
  )
  assert_true(parsed.installed)
  assert_true(parsed.running)
  assert_true(parsed.connected)
  assert_true(!parsed.elevated)
  assert_true(parsed.admin)
  assert_eq(parsed.user_sid, Some("S-1-5-21-1-2-3-1001"))
  assert_eq(parsed.binary, Some("C:\\app\\stillfail-screen-svc.exe"))
}
