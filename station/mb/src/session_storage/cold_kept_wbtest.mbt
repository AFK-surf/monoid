// What an upkeep round asks of each session (`find_room`: its room, every path in use followed) found once, not again
// for each session (cold.mbt `kept_real`, `find_kept`, `follow_kept`).

///|
/// `body` run to its end on a runtime of the test's.
fn run_async(body : async () -> Unit) -> Unit raise {
  let rt = @effect.Runtime::new()
  let f = rt.fork(body)
  rt.advance(10)
  match f.poll() {
    Some(Succeeded(_)) => ()
    Some(Failed(e)) => raise e
    _ => fail("not done")
  }
}

///|
test "the sessions directory followed once found, asked again while it is not there" {
  let cell : Ref[String?] = Ref::new(None)
  let mut asked = 0
  let mut there = false
  let find = async fn() -> String? {
    asked += 1
    if there {
      Some("/real/sessions")
    } else {
      None
    }
  }
  run_async(async fn() {
    assert_eq(kept_real(cell, find), None)
    assert_eq(kept_real(cell, find), None)
    there = true
    for _ in 0..<300 {
      assert_eq(kept_real(cell, find), Some("/real/sessions"))
    }
  })
  assert_eq(asked, 3)
}

///|
test "a room found is kept for a round's sessions, none found asked again, found again once old" {
  let rooms : Map[String, String?] = Map([])
  let at : Map[String, Double] = Map([])
  let mut now = 0.0
  let asked : Map[String, Int] = {}
  let find = async fn(w : String) -> String? {
    asked[w] = asked.get(w).unwrap_or(0) + 1
    if w.has_prefix("/gone") {
      None
    } else {
      Some("room of " + w)
    }
  }
  run_async(async fn() {
    for _ in 0..<5 {
      for i in 0..<256 {
        find_kept(rooms, at, "/w\{i}", () => now, find)
      }
      find_kept(rooms, at, "/gone", () => now, find)
      now += 1000.0
    }
    assert_eq(rooms.get("/w7"), Some(Some("room of /w7")))
    assert_eq(rooms.get("/gone"), Some(None))
    now += followed_ms
    find_kept(rooms, at, "/w7", () => now, find)
  })
  assert_eq(asked.get("/w0"), Some(1))
  assert_eq(asked.get("/w255"), Some(1))
  assert_eq(asked.get("/w7"), Some(2))
  // (a workspace made since is found the next time it is asked)
  assert_eq(asked.get("/gone"), Some(5))
}

///|
test "rooms of a large station all kept for a round, not let go of each other" {
  // (2026-11: a station of 3,998 sessions let go of every room and link each round at 1024, and found them all again)
  let rooms : Map[String, String?] = Map([])
  let at : Map[String, Double] = Map([])
  let mut asked = 0
  let find = async fn(w : String) -> String? {
    asked += 1
    Some(w)
  }
  run_async(async fn() {
    for _ in 0..<3 {
      for i in 0..<1500 {
        find_kept(rooms, at, "/w\{i}", () => 0.0, find)
      }
    }
  })
  assert_eq(rooms.length(), 1500)
  assert_eq(asked, 1500)
  assert_eq(rooms.get("/w0"), Some(Some("/w0")))
}

///|
test "rooms kept at most cache_cap, the least recently found let go first, their times with them" {
  let rooms : Map[String, String?] = Map([])
  let at : Map[String, Double] = Map([])
  run_async(async fn() {
    for i in 0..<(cache_cap + 100) {
      find_kept(rooms, at, "/w\{i}", () => 0.0, async fn(w) { Some(w) })
    }
  })
  assert_eq(rooms.length(), cache_cap)
  assert_eq(at.length(), cache_cap)
  assert_eq(rooms.get("/w0"), None)
  assert_eq(at.get("/w0"), None)
  assert_eq(rooms.get("/w99"), None)
  assert_eq(at.get("/w99"), None)
  assert_eq(rooms.get("/w100"), Some(Some("/w100")))
  assert_true(at.get("/w100") is Some(_))
}

///|
test "the tasks kept going are only those still running" {
  let rt = @effect.Runtime::new()
  let going : Array[@effect.Fiber[Unit]] = []
  let held : @effect.Deferred[Unit] = @effect.Deferred::new()
  let long = rt.fork(async fn() { held.wait() })
  keep_running(going, long)
  for _ in 0..<500 {
    keep_running(going, rt.fork(async fn() { () }))
    rt.advance(1)
  }
  // each ended task let go of as the next is kept: the long one and the last
  assert_eq(going.length(), 2)
  assert_true(physical_equal(going[0], long))
  ignore(held.succeed(()))
  rt.advance(1)
  keep_running(going, rt.fork(async fn() { held.wait() }))
  assert_eq(going.length(), 1)
}

///|
test "a path being followed is not followed again alongside, and is again once that ends" {
  let rt = @effect.Runtime::new()
  let following : Set[String] = Set([])
  let mut started = 0
  let mut gate : @effect.Deferred[Unit] = @effect.Deferred::new()
  let follow = async fn() {
    started += 1
    gate.wait()
  }
  let fork = (f : async () -> Unit) => rt.fork(f)
  let mut forked = 0
  for _ in 0..<300 {
    if follow_once(following, "/p", fork, follow) is Some(_) {
      forked += 1
    }
    rt.advance(1)
  }
  assert_eq(forked, 1)
  assert_eq(started, 1)
  assert_true(following.contains("/p"))
  // another path is followed beside it
  assert_true(follow_once(following, "/q", fork, follow) is Some(_))
  ignore(gate.succeed(()))
  rt.advance(1)
  assert_eq(following.length(), 0)
  // one that fails lets go of its path too
  gate = @effect.Deferred::new()
  let f = follow_once(following, "/p", fork, follow)
  rt.advance(1)
  assert_true(following.contains("/p"))
  ignore(gate.fail(Failure("a link changed as it was followed")))
  rt.advance(1)
  assert_true(f is Some(f) && f.is_done())
  assert_eq(following.length(), 0)
  assert_eq(started, 3)
}

///|
test "a path that fails to follow is not followed again for each session, and is taken as never followed" {
  let followed : Map[String, (Double, String?)] = {}
  let failed : Map[String, Double] = {}
  let mut now = 0.0
  let asked : Map[String, Int] = {}
  let follow = async fn(p : String) -> String? {
    asked[p] = asked.get(p).unwrap_or(0) + 1
    if p == "/broken" {
      fail("a link changed as it was followed")
    }
    Some("/real" + p)
  }
  run_async(async fn() {
    for _ in 0..<256 {
      assert_eq(follow_kept(followed, failed, "/broken", () => now, follow), None)
      assert_eq(follow_kept(followed, failed, "/ok", () => now, follow), Some("/real/ok"))
    }
    // Not kept as followed (`in_room` takes it to be in use), nor followed again in the background meanwhile.
    assert_eq(followed.get("/broken"), None)
    assert_false(follow_due(followed, failed, "/broken", now))
    now += followed_ms
    assert_true(follow_due(followed, failed, "/broken", now))
    assert_eq(follow_kept(followed, failed, "/broken", () => now, follow), None)
  })
  assert_eq(asked.get("/broken"), Some(2))
  assert_eq(asked.get("/ok"), Some(1))
}

///|
test "a path followed after it failed is kept as followed, its failure let go" {
  let followed : Map[String, (Double, String?)] = {}
  let failed : Map[String, Double] = {}
  let mut now = 0.0
  let mut broken = true
  let follow = async fn(p : String) -> String? {
    if broken {
      fail("a link changed as it was followed")
    }
    Some("/real" + p)
  }
  run_async(async fn() {
    assert_eq(follow_kept(followed, failed, "/p", () => now, follow), None)
    broken = false
    now += followed_ms
    assert_eq(follow_kept(followed, failed, "/p", () => now, follow), Some("/real/p"))
    assert_eq(follow_kept(followed, failed, "/p", () => now, follow), Some("/real/p"))
  })
  assert_eq(failed.get("/p"), None)
  assert_eq(followed.get("/p"), Some((followed_ms, Some("/real/p"))))
}

///|
test "a path last followed, failing when followed again, keeps what it was last followed to" {
  let followed : Map[String, (Double, String?)] = { "/p": (0.0, Some("/old")) }
  let failed : Map[String, Double] = {}
  let now = followed_ms
  run_async(async fn() {
    assert_eq(follow_kept(followed, failed, "/p", () => now, async fn(_) { fail("changed") }), None)
  })
  // (`followed_now` answers it whatever its age, as before)
  assert_eq(followed.get("/p"), Some((0.0, Some("/old"))))
  assert_false(follow_due(followed, failed, "/p", now))
}

///|
test "collect_due_paths deduplicates and picks unfollowed or expired job cwds so active jobs are followed before has_jobs" {
  let followed : Map[String, (Double, String?)] = {
    "/fresh": (1000.0, Some("/real/fresh")),
    "/stale": (0.0, Some("/real/stale")),
  }
  let failed : Map[String, Double] = { "/failed-recent": 1000.0 }
  let now = followed_ms + 100.0
  let due = collect_due_paths(
    followed,
    failed,
    ["/fresh", "/new-job", "/new-job", "/stale", "/failed-recent"],
    now,
  )
  assert_eq(due, ["/new-job", "/stale"])
  run_async(async fn() {
    for p in due {
      ignore(follow_kept(followed, failed, p, () => now, async fn(x) { Some("/real" + x) }))
    }
  })
  assert_eq(followed.get("/new-job"), Some((now, Some("/real/new-job"))))
  assert_eq(followed.get("/stale"), Some((now, Some("/real/stale"))))
}

///|
test "parse_rebuild_result and is_incomplete_walk classify complete, duration, entries, and depth walks" {
  let (r1, c1, why1) = parse_rebuild_result({
    "size": 100,
    "complete": true,
    "rebuild": [["/a/node_modules", 64]],
  })
  assert_eq(r1, [("/a/node_modules", 64.0)])
  assert_true(c1)
  assert_eq(why1, None)
  assert_false(is_incomplete_walk(c1, why1, 64.0))

  let (_, c2, why2) = parse_rebuild_result({
    "size": 100,
    "complete": false,
    "reason": "duration",
    "rebuild": [["/a/node_modules", 64]],
  })
  assert_false(c2)
  assert_eq(why2, Some("duration"))
  assert_true(is_incomplete_walk(c2, why2, 0.0))
  assert_true(is_incomplete_walk(c2, why2, 64.0))

  let (_, c3, why3) = parse_rebuild_result({
    "size": 100,
    "complete": false,
    "reason": "entries",
    "rebuild": [["/a/node_modules", 64]],
  })
  assert_false(c3)
  assert_eq(why3, Some("entries"))
  assert_false(is_incomplete_walk(c3, why3, 0.0))
  assert_true(is_incomplete_walk(c3, why3, 64.0))

  let (_, c4, why4) = parse_rebuild_result({
    "size": 100,
    "complete": false,
    "reason": "depth",
    "rebuild": [],
  })
  assert_false(c4)
  assert_eq(why4, Some("depth"))
  assert_false(is_incomplete_walk(c4, why4, 64.0))
}
