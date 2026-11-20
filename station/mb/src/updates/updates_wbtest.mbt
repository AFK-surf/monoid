// Pure unit tests for updates (version comparison, channel offers, platform checks, holds, delta, etc.).

///|
test "versions compared number by number, a longer one newer" {
  assert_true(newer("2.1.9", "2.1.10"))
  assert_true(!newer("2.1.10", "2.1.9"))
  assert_true(newer("1.0", "1.0.0"))
  assert_true(!newer("0.46.0", "0.46.0"))
  assert_true(newer("99999999999999999999.1", "99999999999999999999.2"))
  assert_true(!newer("007", "7"))
}

///|
test "the first dotted version in what a command said" {
  assert_eq(version_in("2.1.284 (Claude Code)"), Some("2.1.284"))
  assert_eq(version_in("codex-cli 0.46.0"), Some("0.46.0"))
  assert_eq(version_in("vv1.2.3"), Some("1.2.3"))
  assert_eq(version_in("1..2"), None)
  assert_eq(version_in("x.1"), None)
  assert_eq(version_in("a 3.x.1 1.2.3"), Some("1.2.3"))
}

///|
test "what is offered: newer by the build, older only back to stable from the beta" {
  assert_eq(offer(Some("0.1.5"), Some("0.1.6"), "stable", "stable"), (true, false))
  assert_eq(offer(Some("0.1.6"), Some("0.1.5"), "stable", "beta"), (false, true))
  assert_eq(offer(Some("0.1.6"), Some("0.1.5"), "beta", "beta"), (false, false))
  assert_eq(offer(Some("0.1.6"), Some("0.2.6"), "stable", "beta"), (false, false))
  assert_eq(offer(None, Some("0.1.6"), "stable", "stable"), (false, false))
  assert_eq(offer(Some("0.1.10"), Some("0.1.9"), "stable", "beta"), (false, true))
}

///|
test "curl's last whole percentage" {
  assert_eq(curl_percent("##########                    33.3%\r######## 50%"), Some(50))
  assert_eq(curl_percent("######## 50.0%\n####### 101%"), Some(50))
  assert_eq(curl_percent("###   45"), None)
  assert_eq(curl_percent("  12%"), Some(12))
  assert_eq(curl_percent("### .5%\r### 1e1%\r### +7%"), Some(7))
  assert_eq(curl_percent(""), None)
}

///|
test "a download's words and share" {
  let (w, p) = downloading("2.1.0", 1500000.0, Some(3000000.0))
  assert_eq(
    stringify(w.to_j()),
    "{\"key\":\"station.updates.downloadingSized\",\"args\":{\"version\":\"2.1.0\",\"got\":2,\"mb\":3}}",
  )
  assert_eq(p, Some(50))
  let (w2, p2) = downloading("2.1.0", 2500000.0, None)
  assert_eq(stringify(w2.to_j()), "{\"key\":\"station.updates.downloadingSoFar\",\"args\":{\"version\":\"2.1.0\",\"mb\":3}}")
  assert_eq(p2, None)
  assert_true(step_of("  ==> Pouring codex") is Some(Key("station.updates.installing", None)))
  assert_true(step_of("something else") is None)
}

///|
test "a key's id: the first 16 hex digits of its sha256" {
  assert_eq(key_id("vJeYSXYJW04ANrn49w+I7nzS/8NFsh1MKwRCiJ8PVPI="), "3c2d0f7ad7f9eca2")
  assert_eq(key_id("pvYJzkDfZGPRIPSLQ0jQDTXwhkwfbMsUtXxdVavugxc="), "d3353d225efaaecd")
  assert_eq(trusted_keys(None).length(), 2)
}

///|
test "what is allowed: a newer build, or back to stable from the beta" {
  let r = jo([("build", ji(5))])
  assert_true(allowed(r, None, "stable", None))
  assert_true(!allowed(r, Some(6.0), "stable", Some("stable")))
  assert_true(allowed(r, Some(6.0), "stable", Some("beta")))
  assert_true(!allowed(r, Some(6.0), "beta", Some("beta")))
}

///|
test "a delta's paths an applier refuses" {
  for p in ["", "/abs", "C:x", "a\\b", "a//b", "a/../b", "..", "a/"] {
    assert_true((try Some(check_path(p)) catch { _ => None }) is None)
  }
  for p in ["ok/file", "./a", "é/ü"] {
    assert_true((try Some(check_path(p)) catch { _ => None }) is Some(_))
  }
}

///|
/// A delta of one file `f` from `old` making `made`, its chunk the records given.
fn one_delta(old : Bytes, made : Int, records : Bytes) -> Bytes {
  let b = Buffer()
  b.write_bytes(delta_magic)
  let u32 = (v : Int) => {
    b.write_byte(v.to_byte())
    b.write_byte((v >> 8).to_byte())
    b.write_byte((v >> 16).to_byte())
    b.write_byte((v >> 24).to_byte())
  }
  let u64 = (v : Int) => {
    u32(v)
    u32(0)
  }
  u32(1)
  b.write_byte(b'\x01')
  b.write_byte(b'\x00')
  b.write_byte(b'f')
  u32(0)
  u64(old.length())
  b.write_bytes(unhex(sha256(old)))
  u32(0)
  u64(made)
  // a stored deflate block of the records
  let n = records.length()
  u32(n)
  u32(n + 5)
  b.write_byte(b'\x01')
  b.write_byte(n.to_byte())
  b.write_byte((n >> 8).to_byte())
  b.write_byte((n ^ 0xffff).to_byte())
  b.write_byte(((n ^ 0xffff) >> 8).to_byte())
  b.write_bytes(records)
  u32(0)
  u32(0)
  b.to_bytes()
}

///|
fn record(x : Int, y : Int, z : Int) -> Bytes {
  let b = Buffer()
  for v in [x, y, z] {
    let lo = v
    let hi = if v < 0 { -1 } else { 0 }
    for k in 0..<4 {
      b.write_byte((lo >> (8 * k)).to_byte())
    }
    for k in 0..<4 {
      b.write_byte((hi >> (8 * k)).to_byte())
    }
  }
  b.to_bytes()
}

///|
/// `f` run to its end on a runtime of its own (it waits on nothing outside).
fn[X] ran(f : async () -> X) -> X {
  let rt = @effect.Runtime::new()
  let fiber = rt.fork(f)
  ignore(rt.run_ready())
  match fiber.poll() {
    Some(Succeeded(v)) => v
    _ => abort("it did not end")
  }
}

///|
test "a delta applied: diff bytes added to the old, extra bytes as they are" {
  let old = b"0123456789abcdef"
  let recs = Buffer()
  recs.write_bytes(record(4, 2, -2))
  recs.write_bytes(b"\x01\x01\x01\x01")
  recs.write_bytes(b"XY")
  recs.write_bytes(record(2, 0, 0))
  recs.write_bytes(b"\x00\x00")
  let d = one_delta(old, 8, recs.to_bytes())
  let h = parse_header(d)
  assert_eq(h.files, ["f"])
  assert_eq(h.made_size, 8.0)
  let out = Buffer()
  ran(async fn() { apply(h, old, d, fn(b) { out.write_bytes(b) }, fn(b) { b }) catch { _ => () } })
  // (the second record reads from where the first left the old, two back: "23")
  assert_eq(out.to_bytes(), b"1234XY23")
}

///|
test "a delta refused: a record past what it makes" {
  let old = b"0123456789abcdef"
  let d = one_delta(old, 4, record(5, 0, 0))
  let got = ran(async fn() {
    (try {
      apply(parse_header(d), old, d, fn(_) {  }, fn(b) { b })
      None
    } catch {
      e => Some(message_of(e))
    })
  })
  assert_eq(got, Some("a record goes past made_size"))
}

///|
test "a header refused" {
  let refused = (b : Bytes) => (try { ignore(parse_header(b)); "" } catch { e => message_of(e) })
  assert_eq(refused(b"SFDELTA0"), "not a delta (bad magic)")
  assert_eq(refused(b"SFDELTA1"), "the delta's header is cut short")
}

///|
test "a file under /releases/" {
  assert_true(release_file("station/5-6.delta"))
  assert_true(!release_file("../x"))
  assert_true(!release_file("a/./b"))
  assert_true(!release_file("a b"))
  assert_true(!release_file(""))
}

///|
test "Number() of a header" {
  assert_eq(js_number(" 12 "), 12.0)
  assert_eq(js_number(""), 0.0)
  assert_eq(js_number("0x10"), 16.0)
  assert_true(js_number("abc") != js_number("abc"))
}

///|
test "codex features list says it uses the host" {
  assert_true(uses_codex_host("unified_exec  stable  true\ncode_mode_host  under development  true\n"))
  assert_true(!uses_codex_host("code_mode_host true"))
  assert_true(uses_codex_host("code_mode_host  true"))
  assert_true(!uses_codex_host("code_mode_host removed true"))
  assert_true(uses_codex_host("code_mode_host  removed  true"))
  assert_true(uses_codex_host("code_mode_host removedx  true"))
  assert_true(!uses_codex_host("code_mode_host x false"))
}

///|
test "the backoff of a failed update's retry: the shorter of doubling from two minutes and fifteen" {
  assert_eq([0, 1, 2, 3, 4, 5].map(station_retry_backoff), [120000.0, 240000.0, 480000.0, 900000.0, 900000.0, 900000.0])
}

///|
test "how a runtime is named, its command and package" {
  assert_eq(kind_name("station"), "Station")
  assert_eq(kind_name("dsh"), "DeepSeek Harness")
  assert_eq(kind_command("station"), "stillfail-station")
  assert_eq(kind_package("pi"), "@earendil-works/pi-coding-agent")
  assert_eq(kind_package("devin"), "")
  let pinned = pin_npm_version(how_of(jo([("program", js("npm")), ("args", jstrs(["install", "-g", "@openai/codex@latest"]))])), "@openai/codex", "0.47.0")
  assert_eq(pinned.args, ["install", "-g", "@openai/codex@0.47.0", "--prefer-online"])
  assert_true(is_npm_install(how_of(jo([("program", js("/a/NPM.cmd")), ("args", jstrs(["install"]))]))))
  assert_true(!is_npm_install(how_of(jo([("program", js("/a/npx")), ("args", jstrs(["install"]))]))))
}

///|
test "holds: the last let go tells, once" {
  let told = Ref(0)
  let stop = on_let_go(() => told.val += 1)
  let a = hold()
  let b = hold()
  assert_eq(holding(), 2)
  a()
  a()
  assert_eq(told.val, 0)
  b()
  assert_eq(told.val, 1)
  assert_eq(holding(), 0)
  stop()
}

///|
test "the applier apart: a checkout's delta.ts, a release's main.js, or the station's own program with no Node" {
  assert_eq(apart_args("/r/scripts/delta.ts", "/a", "/d", "/o"), [
    "/r/scripts/delta.ts", "apply", "--old", "/a", "--delta", "/d", "--out", "/o",
  ])
  assert_eq(apart_args("main.js", "/a", "/d", "/o"), [
    "main.js", "update", "--apply-delta", "--app", "/a", "--delta", "/d", "--out", "/o",
  ])
  assert_eq(apart_args("", "/a", "/d", "/o"), [
    "update", "--apply-delta", "--app", "/a", "--delta", "/d", "--out", "/o",
  ])
}
