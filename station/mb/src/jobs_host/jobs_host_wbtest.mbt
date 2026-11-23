// Pure logic tests for jobs_host: job records, naming, exit codes, log file IDs, load summaries, Net state,
// URL resolution, and workspace size serialization.

///|
test "job_json strips token, renames sessionKey, and keeps true flags only" {
  let raw : Json = {
    "id": "j1",
    "sessionKey": "s1",
    "token": "secret",
    "name": "build",
    "command": "make",
    "cwd": "/tmp",
    "port": 3000,
    "state": "running",
    "pgid": 42,
    "exitCode": null,
    "startedAt": 100,
    "endedAt": null,
    "restarts": 0,
    "log": "/tmp/j1.log",
    "watch": false,
    "queued": true,
    "screen": false,
    "small": true,
  }
  let out = job_json(raw)
  assert_eq(field(out, "token"), None)
  assert_eq(field(out, "session"), Some(jstr("s1")))
  assert_eq(field(out, "queued"), Some(jbool(true)))
  assert_eq(field(out, "screen"), None)
  assert_eq(field(out, "small"), Some(jbool(true)))
}

///|
test "job naming, queue prefix, and moved_said formatting" {
  assert_true(queues("remote_abc"))
  assert_false(queues("job_abc"))
  assert_eq(job_named("j1", "dev", None), "Job \"dev\" (j1)")
  assert_eq(job_named("j2", "web", Some(8080.0)), "Service \"web\" (j2, port 8080)")
  assert_eq(
    moved_said("Moved", Some("j1"), "web", Some(3000.0), None),
    "Moved; Service \"web\" (j1, port 3000) was started again.",
  )
  assert_eq(
    moved_said("Moved", None, "worker", None, Some("port busy")),
    "Moved; Job \"worker\" could not be started again: port busy",
  )
  assert_eq(
    moved_said("Moved", Some(""), "api", Some(80.0), None),
    "Moved; Service \"api\" (port 80) was started again.",
  )
}

///|
test "shown_name trims, truncates to 60 code points, and falls back to command" {
  assert_eq(shown_name("  my job  ", "echo hi"), "my job")
  assert_eq(shown_name("   ", "  npm run dev "), "npm")
  assert_eq(shown_name("", "   "), "job")
  let long_name = "a".repeat(75)
  assert_eq(shown_name(long_name, "cmd").length(), 60)
}

///|
test "exit_code_of parses signed integer strings and rejects garbage" {
  assert_eq(exit_code_of("0"), Some(0.0))
  assert_eq(exit_code_of("  +42\n"), Some(42.0))
  assert_eq(exit_code_of("-15"), Some(-15.0))
  assert_eq(exit_code_of(""), None)
  assert_eq(exit_code_of("12a"), None)
  assert_eq(exit_code_of("1.5"), None)
}

///|
test "held_claims filters valid integer-pid entries and preserves since" {
  assert_eq(held_claims(None), Json::array([]))
  assert_eq(held_claims(Some("not json")), Json::array([]))
  let parsed = held_claims(
    Some("[{\"job\":\"j1\",\"pid\":123,\"at\":1000,\"since\":900},{\"job\":\"j2\",\"pid\":1.5,\"at\":2000},{\"job\":\"j3\",\"pid\":456,\"at\":3000}]"),
  )
  inspect(
    parsed.stringify(),
    content="[{\"job\":\"j1\",\"pid\":123,\"at\":1000,\"held\":true,\"since\":900},{\"job\":\"j3\",\"pid\":456,\"at\":3000,\"held\":true}]",
  )
}

///|
test "job_file_id and bearer token parsing" {
  assert_eq(job_file_id("abc.log", "logs"), Some("abc"))
  assert_eq(job_file_id("abc.log.1.tmp", "logs"), Some("abc"))
  assert_eq(job_file_id("abc.txt", "logs"), None)
  assert_eq(job_file_id("abc.lost", "exit"), Some("abc"))
  assert_eq(job_file_id("abc", "exit"), Some("abc"))
  assert_eq(bearer(Some("Bearer tok123")), "tok123")
  assert_eq(bearer(Some("Basic xyz")), "")
  assert_eq(bearer(None), "")
}

///|
test "load summary, detailed, and Net relay state" {
  assert_eq(summary(Json::null()), older)
  assert_eq(summary({ "unavailable": "offline" }), "unknown (offline)")
  let gib = 1073741824.0
  let load : Json = {
    "arch": "arm64",
    "os": "darwin",
    "cpus": 16,
    "cpuModel": "Apple M4 Max",
    "gpus": [
      { "name": "Apple M4 Max", "cores": 40 },
      { "name": "RTX 4090", "memoryTotalBytes": 24.0 * gib, "memoryUsedBytes": 4.0 * gib, "busy": 0.25 },
    ],
    "cpuBusy": { "share": 0.42, "seconds": 60 },
    "loadAvg": [1.5, 1.2, 0.9],
    "memory": { "totalBytes": 128.0 * gib, "availableBytes": 64.5 * gib },
    "disk": { "totalBytes": 500.0 * gib, "freeBytes": 200.0 * gib },
    "running": { "remoteTasks": 1, "jobs": 2, "services": 0, "turns": 1 },
    "relay": { "ping": { "ms": 18 } },
  }
  inspect(
    summary(load),
    content="arm64 darwin, 16 cores (Apple M4 Max), GPU 40 cores, GPU RTX 4090 (20 GiB of 24 GiB free, 25% busy); CPU 42% busy over the last 60 s, load 1.5 / 1.2 / 0.9 (1 / 5 / 15 min); memory 64.5 GiB of 128 GiB free, disk 200 GiB of 500 GiB free; running 1 remote task, 2 jobs, 0 services, 1 agent turn; relay ping 18 ms",
  )
  assert_eq(field(detailed({ "id": "st1" }), "load"), Some(jstr(older)))
  assert_eq(field(detailed({ "load": { "unavailable": "busy" } }), "summary"), Some(jstr("unknown (busy)")))

  let net = Net::new()
  assert_eq(net.seen(), Json::null())
  let detach = net.attach(() => Some("https://relay.example"))
  net.pinged("https://relay.example", 12.6)
  inspect(net.seen().stringify(), content="{\"home\":\"https://relay.example\",\"ping\":{\"relay\":\"https://relay.example\",\"ms\":13}}")
  detach()
  assert_eq(net.seen(), Json::null())
}

///|
test "resolve_url and WorkspaceSize::to_json" {
  let base = @cloud_net.parse_url("https://example.com/a/b/page.html?x=1").unwrap()
  assert_eq(resolve_url("c.js", base).map(u => u.href()), Some("https://example.com/a/b/c.js"))
  assert_eq(resolve_url("/root", base).map(u => u.href()), Some("https://example.com/root"))
  assert_eq(resolve_url("//cdn.example/x", base).map(u => u.href()), Some("https://cdn.example/x"))
  assert_eq(resolve_url("?q=2", base).map(u => u.href()), Some("https://example.com/a/b/page.html?q=2"))
  assert_eq(resolve_url("#top", base).map(u => u.href()), Some("https://example.com/a/b/page.html?x=1#top"))
  assert_eq(resolve_url("https:sub", base).map(u => u.href()), Some("https://example.com/a/b/sub"))
  assert_eq(WorkspaceSize::{ bytes: 512.0, complete: true, truncated: false }.to_json().stringify(), "{\"bytes\":512,\"complete\":true}")
  assert_eq(WorkspaceSize::{ bytes: 1024.0, complete: false, truncated: true }.to_json().stringify(), "{\"bytes\":1024,\"complete\":false,\"truncated\":true}")
}

///|
test "a job's shell starts without the launcher's front" {
  let script = spawn_script(10)
  assert_true(script.has_prefix("unset STILLFAIL_MESH_FRONT; "))
  assert_true(spawn_script(0).has_prefix("unset STILLFAIL_MESH_FRONT; "))
}

///|
test "station_list's line for a rig safe mode has not taken yet: not asked, whose, why (remote.ts `rigWaiting`, FB-45)" {
  let rig : Json = {
    "id": "r1",
    "name": "build-box",
    "owner": "u1",
    "owner_email": "pat@example.com",
    "owner_name": "Pat",
    "version": "0.1.0",
  }
  assert_eq(rig_waiting(rig), {
    "id": "r1",
    "name": "build-box",
    "mode": "tasks",
    "owner": "pat@example.com",
    "version_seen": "0.1.0",
    "unprotected": "not taken into this workspace yet: its owner pat@example.com has to check its security code in still.fail first",
  })
  let bare : Json = { "id": "r2", "name": "box" }
  assert_eq(rig_waiting(bare), {
    "id": "r2",
    "name": "box",
    "mode": "tasks",
    "unprotected": "not taken into this workspace yet: its owner has to check its security code in still.fail first",
  })
}

///|
test "collect_files batch mode queries in chunks of 500, skips up, and yields to timer fibers" {
  let rt = @effect.Runtime::new(start=0L)
  let now = 1_000_000_000_000.0
  let log_names : Array[String] = ["up.log"]
  let exit_names : Array[String] = ["up"]
  for i in 0..<1200 {
    log_names.push("kept\{i}.log")
    exit_names.push("kept\{i}")
  }
  let batch_sizes : Array[Int] = []
  let queried_up : Ref[Bool] = { val: false }
  let removed : Array[String] = []
  let ticks : Ref[Int] = { val: 0 }
  let collecting : Ref[Bool] = { val: true }
  let result : Ref[Array[String]?] = { val: None }
  let ticker = rt.fork(name="ticker", async fn() {
    while collecting.val {
      @effect.sleep(1) // timer: test fiber checking that collect_files yields to the host event loop
      ticks.val += 1
    }
  })
  let worker = rt.fork(name="collect", async fn() {
    let gone = collect_files(
      "/jobs",
      now,
      ["up"],
      async fn(d) { if d.has_suffix("/logs") { log_names } else { exit_names } },
      async fn(_) { None },
      async fn(f) { removed.push(f) },
      _ => false,
      _ => None,
      jobs_of=Some(ids => {
        batch_sizes.push(ids.length())
        let m : Map[String, Json] = {}
        for id in ids {
          if id == "up" {
            queried_up.val = true
          }
          m[id] = { "state": "exited", "endedAt": jnum(now - 1000.0) }
        }
        Some(m)
      }),
    )
    collecting.val = false
    result.val = Some(gone)
  })
  ignore(rt.run_ready())
  while !worker.is_done() {
    rt.advance(1)
  }
  rt.advance(1)
  assert_true(ticker.is_done())
  assert_eq(result.val, Some([]))
  assert_eq(removed.length(), 0)
  assert_false(queried_up.val)
  assert_true(batch_sizes.length() <= 3)
  assert_true(batch_sizes.length() >= 1)
  for n in batch_sizes {
    assert_true(n <= collect_batch_size)
  }
  assert_true(ticks.val >= 2)
}

///|
test "collect_files batch mode skips files safely when batch lookup returns None" {
  let rt = @effect.Runtime::new(start=0L)
  let now = 1_000_000_000_000.0
  let old_mtime = now - job_files_orphan_ms - 60_000.0
  let removed : Array[String] = []
  let result : Ref[Array[String]?] = { val: None }
  let worker = rt.fork(name="collect-db-err", async fn() {
    result.val = Some(
      collect_files(
        "/jobs",
        now,
        [],
        async fn(d) { if d.has_suffix("/logs") { ["a.log", "b.log"] } else { ["a", "b"] } },
        async fn(_) { Some({ "mtimeMs": jnum(old_mtime) }) },
        async fn(f) { removed.push(f) },
        _ => false,
        _ => None,
        jobs_of=Some(_ => None),
      ),
    )
  })
  ignore(rt.run_ready())
  while !worker.is_done() {
    rt.advance(1)
  }
  assert_eq(result.val, Some([]))
  assert_eq(removed.length(), 0)
}

///|
test "collect_files fallback single-lookup mode yields at most collect_yield_every reads per turn" {
  let rt = @effect.Runtime::new(start=0L)
  let now = 1_000_000_000_000.0
  let log_names : Array[String] = []
  let exit_names : Array[String] = []
  for i in 0..<200 {
    log_names.push("j\{i}.log")
    exit_names.push("j\{i}")
  }
  let reads : Ref[Int] = { val: 0 }
  let last_reads : Ref[Int] = { val: 0 }
  let max_per_turn : Ref[Int] = { val: 0 }
  let ticks : Ref[Int] = { val: 0 }
  let collecting : Ref[Bool] = { val: true }
  let result : Ref[Array[String]?] = { val: None }
  let ticker = rt.fork(name="ticker", async fn() {
    while collecting.val {
      @effect.sleep(1) // timer: test fiber measuring reads per event-loop turn
      let delta = reads.val - last_reads.val
      if delta > max_per_turn.val {
        max_per_turn.val = delta
      }
      last_reads.val = reads.val
      ticks.val += 1
    }
  })
  let worker = rt.fork(name="collect-single", async fn() {
    let gone = collect_files(
      "/jobs",
      now,
      [],
      async fn(d) { if d.has_suffix("/logs") { log_names } else { exit_names } },
      async fn(_) { None },
      async fn(_) { () },
      _ => false,
      _ => {
        reads.val += 1
        Some({ "state": "exited", "endedAt": jnum(now - 1000.0) })
      },
    )
    collecting.val = false
    result.val = Some(gone)
  })
  ignore(rt.run_ready())
  while !worker.is_done() {
    rt.advance(1)
  }
  rt.advance(1)
  assert_true(ticker.is_done())
  let tail_delta = reads.val - last_reads.val
  if tail_delta > max_per_turn.val {
    max_per_turn.val = tail_delta
  }
  assert_eq(result.val, Some([]))
  assert_eq(reads.val, 200)
  assert_true(max_per_turn.val <= collect_yield_every)
  assert_true(ticks.val >= 5)
}

///|
test "collect_files deduplicates 5000 expired jobs in O(N), respects is_running race and orphan mtime" {
  let rt = @effect.Runtime::new(start=0L)
  let now = 1_000_000_000_000.0
  let expired_at = now - job_logs_kept_ms - 1.0
  let log_names : Array[String] = ["restarted.log", "orphan_old.log", "orphan_fresh.log"]
  let exit_names : Array[String] = ["restarted", "orphan_old", "orphan_fresh"]
  for i in 0..<5000 {
    log_names.push("exp\{i}.log")
    exit_names.push("exp\{i}")
  }
  let removed : Array[String] = []
  let result : Ref[Array[String]?] = { val: None }
  let worker = rt.fork(name="collect-5000", async fn() {
    result.val = Some(
      collect_files(
        "/jobs",
        now,
        [],
        async fn(d) { if d.has_suffix("/logs") { log_names } else { exit_names } },
        async fn(f) {
          if f.contains("orphan_old") {
            Some({ "mtimeMs": jnum(now - job_files_orphan_ms - 1.0) })
          } else if f.contains("orphan_fresh") {
            Some({ "mtimeMs": jnum(now - job_files_orphan_ms + 1000.0) })
          } else {
            None
          }
        },
        async fn(f) { removed.push(f) },
        id => id == "restarted",
        id => if id == "restarted" { Some({ "state": "running", "endedAt": Json::null() }) } else { None },
        jobs_of=Some(ids => {
          let m : Map[String, Json] = {}
          for id in ids {
            if id.has_prefix("exp") || id == "restarted" {
              m[id] = { "state": "exited", "endedAt": jnum(expired_at) }
            }
          }
          Some(m)
        }),
      ),
    )
  })
  ignore(rt.run_ready())
  while !worker.is_done() {
    rt.advance(1)
  }
  let gone = result.val.unwrap()
  // 5000 expired + 1 orphan_old = 5001 unique ids; restarted and orphan_fresh stay.
  assert_eq(gone.length(), 5001)
  assert_eq(removed.length(), 10002)
  assert_false(gone.contains("restarted"))
  assert_false(gone.contains("orphan_fresh"))
  assert_true(gone.contains("orphan_old"))
}
