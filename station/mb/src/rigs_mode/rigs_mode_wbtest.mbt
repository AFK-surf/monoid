// What of these parts needs no station: whose a task's job is, the disk's marks, the door's ports, the words an agent
// reads, the forms' shapes, JSON as JavaScript writes it, and the parts of a rig's process put together over fakes.
// (What asks the station is held to the TypeScript by station/test/mb-rigs-mode.test.ts.)

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
