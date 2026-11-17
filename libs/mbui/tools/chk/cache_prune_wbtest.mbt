///|
test "a rolling cache's kind" {
  assert_eq(
    kind_of("mbui-apk-09b758a048c406bf0db415ad3709264632d1cb5b"),
    Some("mbui-apk"),
  )
  assert_eq(
    kind_of("mbui-linux-store-lto-app-00b78fb4840fdc3e"),
    Some("mbui-linux-store-lto-app"),
  )
  // A Mac runner image changes its compiler launcher. Each launcher's store must retain its own newest cache.
  assert_eq(
    kind_of("mbui-mac-cc-61e77a2d557f8677-00b78fb4840fdc3e"),
    Some("mbui-mac-cc-61e77a2d557f8677"),
  )
  assert_eq(
    kind_of("mbui-branch-mac-cc-61e77a2d557f8677-e8e9dcee15240fe7"),
    Some("mbui-branch-mac-cc-61e77a2d557f8677"),
  )
  assert_eq(
    kind_of("mbui-mac-cc-f39ac2e5baa34bad-1234567890abcdef"),
    Some("mbui-mac-cc-f39ac2e5baa34bad"),
  )
  assert_eq(
    kind_of(
      "gradle-home-v1|Linux-X64|check-android[2face68063188a806d63532a8cee1e9b]-09b758a048c406bf0db415ad3709264632d1cb5b",
    ),
    Some("gradle-home-v1|Linux-X64|check-android[2face68063188a806d63532a8cee1e9b]"),
  )
  assert_eq(kind_of("mbui-ios-build-39731343052-1"), Some("mbui-ios-build"))
  assert_eq(kind_of("warp-1.0.21"), None)
  assert_eq(kind_of("android-image-36-google_apis-x86_64-7"), None)
  assert_eq(kind_of("android-ndk-28.2.13676358-Linux-X64"), None)
  assert_true(is_gradle_part("gradle-transforms-v1-8bc0a5259a7f8a719cff172016a05c50"))
  assert_false(is_gradle_part("gradle-home-v1|Linux-X64|x[2face68063188a806d63532a8cee1e9b]-09b758a0"))
}

///|
test "a time of GitHub's in seconds" {
  assert_eq(iso_s("1970-01-01T00:00:00Z"), 0.0)
  assert_eq(iso_s("2026-10-22T05:37:59.731503Z"), 1792647479.0)
}

///|
test "only old caches of deleted branches are removed" {
  let heads : Map[String, Bool] = { "refs/heads/main": true, "refs/heads/live": true }
  let cache : Cache = {
    id: "1", key: "any-key", ref_: "refs/heads/gone", size: 10L, created: 1000.0, accessed: 1000.0,
  }
  assert_true(deleted_head_cache(cache, heads, 2800.0))
  assert_false(deleted_head_cache({ ..cache, ref_: "refs/heads/live" }, heads, 2800.0))
  assert_false(deleted_head_cache({ ..cache, ref_: "refs/pull/123/merge" }, heads, 2800.0))
  assert_false(deleted_head_cache({ ..cache, ref_: "refs/tags/old" }, heads, 2800.0))
  assert_false(deleted_head_cache({ ..cache, created: 1001.0 }, heads, 2800.0))
  assert_false(deleted_head_cache({ ..cache, accessed: 1001.0 }, heads, 2800.0))
  assert_false(deleted_head_cache({ ..cache, created: 0.0 }, heads, 2800.0))
  assert_false(deleted_head_cache({ ..cache, accessed: 0.0 }, heads, 2800.0))
}

///|
test "a branch name is one shell argument" {
  assert_eq(shell_arg("can't;$(echo bad)"), "'can'\\''t;$(echo bad)'")
}

///|
test "a branch's caches not read for 12 hours go, the default branch's and pull requests' stay" {
  let h = 3600.0
  let cache : Cache = { id: "1", key: "k-0123456789abcdef", ref_: "refs/heads/done", size: 5000000L, created: 1.0, accessed: 1.0 }
  assert_true(idle_branch_cache(cache, "refs/heads/main", 1.0 + 12.0 * h))
  assert_false(idle_branch_cache(cache, "refs/heads/main", 12.0 * h))
  assert_false(idle_branch_cache({ ..cache, ref_: "refs/heads/main" }, "refs/heads/main", 1.0 + 24.0 * h))
  assert_false(idle_branch_cache({ ..cache, ref_: "refs/pull/1/merge" }, "refs/heads/main", 1.0 + 24.0 * h))
  assert_false(idle_branch_cache({ ..cache, accessed: 0.0 }, "refs/heads/main", 1.0 + 24.0 * h))
}

///|
test "a call of GitHub's API that fails twice is made a third time" {
  let mut runs = 0
  let mut pauses = 0
  let mut asked = ""
  let got = gh_lines_by(
    "api repos/o/r/branches",
    fn(cmd) {
      runs += 1
      asked = cmd
      if runs < 3 {
        None
      } else {
        Some("main\nfeat\n")
      }
    },
    fn() { pauses += 1 },
  )
  assert_eq(got, Some(["main", "feat"]))
  assert_eq(asked, "gh api repos/o/r/branches")
  assert_eq(runs, 3)
  assert_eq(pauses, 2)
}

///|
test "a call of GitHub's API that fails three times is failed, so nothing is deleted" {
  let mut runs = 0
  let mut pauses = 0
  let got = gh_lines_by(
    "api repos/o/r/branches",
    fn(_) {
      runs += 1
      None
    },
    fn() { pauses += 1 },
  )
  assert_eq(got, None)
  assert_eq(runs, 3)
  assert_eq(pauses, 2)
}

///|
test "a delete answered 502 while the cache is still there is made again" {
  let mut deletes = 0
  let mut pauses = 0
  let got = delete_cache_by(
    fn() {
      deletes += 1
      if deletes == 1 {
        "gh: Server Error (HTTP 502)\nexit=1"
      } else {
        "exit=0"
      }
    },
    fn() { true },
    fn() { pauses += 1 },
  )
  assert_eq(got, None)
  assert_eq(deletes, 2)
  assert_eq(pauses, 1)
}

///|
test "a delete answered 502 three times while the cache is still there fails" {
  let mut deletes = 0
  let mut pauses = 0
  let got = delete_cache_by(
    fn() {
      deletes += 1
      "gh: Server Error (HTTP 502)\nexit=1"
    },
    fn() { true },
    fn() { pauses += 1 },
  )
  assert_eq(got, Some("gh: Server Error (HTTP 502)\nexit=1"))
  assert_eq(deletes, 3)
  assert_eq(pauses, 2)
}

///|
test "a delete answered 502 that was done all the same, or answered 404, is done" {
  let mut deletes = 0
  assert_eq(
    delete_cache_by(
      fn() {
        deletes += 1
        "gh: Server Error (HTTP 502)\nexit=1"
      },
      fn() { false },
      fn() { () },
    ),
    None,
  )
  assert_eq(deletes, 1)
  assert_eq(
    delete_cache_by(fn() { "gh: Not Found (HTTP 404)\nexit=1" }, fn() { true }, fn() { () }),
    None,
  )
}

///|
fn ids_of(cs : Array[Cache]) -> Array[String] {
  cs.map(fn(c) { c.id })
}

///|
test "under the cap nothing more goes" {
  let m : Cache = { id: "1", key: "warp-1.0.21", ref_: "refs/heads/main", size: 4000L, created: 1.0, accessed: 1.0 }
  let kept = [m, { ..m, id: "2", ref_: "refs/heads/feat", size: 5000L }]
  assert_eq(ids_of(over_cap_caches(kept, "refs/heads/main", 9000L)), [])
  assert_eq(ids_of(over_cap_caches(kept, "refs/heads/main", 10000L)), [])
}

///|
test "over the cap the least recently read of other refs go, till it holds; main's and markers stay" {
  let mb = 1000000L
  let c : Cache = { id: "0", key: "k-0123456789abcdef", ref_: "refs/heads/main", size: 0L, created: 1.0, accessed: 1.0 }
  let kept = [
    // main's, read least recently of all and over the cap alone: never taken
    { ..c, id: "1", size: 30L * mb, accessed: 1.0 },
    // a marker under a megabyte, on a branch, read long ago: stays
    { ..c, id: "2", ref_: "refs/heads/old", size: mb - 1L, accessed: 2.0 },
    // a pull request's, the oldest read of the rest: first
    { ..c, id: "3", ref_: "refs/pull/7/merge", size: 3L * mb, accessed: 3.0 },
    // two read at once: the older made first, then by id
    { ..c, id: "12", ref_: "refs/heads/a", size: 4L * mb, created: 2.0, accessed: 4.0 },
    { ..c, id: "11", ref_: "refs/heads/b", size: 4L * mb, created: 1.0, accessed: 4.0 },
    { ..c, id: "10", ref_: "refs/heads/c", size: 4L * mb, created: 2.0, accessed: 4.0 },
    // the newest read: kept
    { ..c, id: "5", ref_: "refs/heads/live", size: 6L * mb, accessed: 9.0 },
  ]
  let total = kept.fold(init=0L, fn(a, x) { a + x.size })
  // 3 MB over: the pull request's alone
  assert_eq(ids_of(over_cap_caches(kept, "refs/heads/main", total - 3L * mb)), ["3"])
  // 3 MB and one byte over: then the oldest made of the two read at 4, then the lower id of the rest
  assert_eq(ids_of(over_cap_caches(kept, "refs/heads/main", total - 3L * mb - 1L)), ["3", "11"])
  assert_eq(ids_of(over_cap_caches(kept, "refs/heads/main", total - 7L * mb - 1L)), ["3", "11", "10"])
  // far over (main's alone is past the cap): every other ref's of a megabyte or more, main's and the marker kept
  assert_eq(
    ids_of(over_cap_caches(kept, "refs/heads/main", 10L * mb)),
    ["3", "11", "10", "12", "5"],
  )
}
