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
  // native.ts's parts by their 24-digit hashes: one kind of each count of parts, a 16-digit one before the last kept
  let h24 = "93ac1e021fe42463dcc143f8"
  assert_eq(
    kind_of("natives-win32-x64-3081244fef5b6070760f83bb-\{h24}-f5c8c5a0e8181ad319943372"),
    Some("natives-win32-x64-<24>-<24>"),
  )
  assert_eq(
    kind_of("natives-win32-x64-013477436c26ce374343cc87-\{h24}"),
    Some("natives-win32-x64-<24>"),
  )
  assert_eq(
    kind_of("natives-linux-arm64-37b29033706baf9113f6e675-cbb701e1150a3dc5a2ca2edb-5a93a93cf978a3d99d45b0f3"),
    Some("natives-linux-arm64-<24>-<24>"),
  )
  assert_eq(
    kind_of("natives-shell-apple-darwin-arm64-f4c138fb22fd25afa10653dc"),
    Some("natives-shell-apple-darwin-arm64"),
  )
  assert_eq(kind_of("\{h24}-\{h24}"), Some(h24))
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
test "a deleted branch's caches go 5 minutes after last made or read" {
  let heads : Map[String, Bool] = { "refs/heads/main": true, "refs/heads/live": true }
  let cache : Cache = {
    id: "1", key: "any-key", ref_: "refs/heads/gone", size: 10L, created: 1000.0, accessed: 1000.0,
  }
  // 5 minutes (300 s) after it was last made or read
  assert_true(deleted_head_cache(cache, heads, 1300.0))
  assert_false(deleted_head_cache(cache, heads, 1299.0))
  assert_false(deleted_head_cache({ ..cache, ref_: "refs/heads/live" }, heads, 1300.0))
  assert_false(deleted_head_cache({ ..cache, ref_: "refs/pull/123/merge" }, heads, 1300.0))
  assert_false(deleted_head_cache({ ..cache, ref_: "refs/tags/old" }, heads, 1300.0))
  assert_false(deleted_head_cache({ ..cache, created: 1001.0 }, heads, 1300.0))
  assert_false(deleted_head_cache({ ..cache, accessed: 1001.0 }, heads, 1300.0))
  assert_false(deleted_head_cache({ ..cache, created: 0.0 }, heads, 1300.0))
  assert_false(deleted_head_cache({ ..cache, accessed: 0.0 }, heads, 1300.0))
}

///|
test "a branch name is one shell argument" {
  assert_eq(shell_arg("can't;$(echo bad)"), "'can'\\''t;$(echo bad)'")
}

///|
test "a branch's caches not read for 2 hours go, the default branch's and pull requests' stay" {
  let h = 3600.0
  let cache : Cache = { id: "1", key: "k-0123456789abcdef", ref_: "refs/heads/done", size: 5000000L, created: 1.0, accessed: 1.0 }
  assert_true(idle_branch_cache(cache, "refs/heads/main", 1.0 + 2.0 * h))
  assert_false(idle_branch_cache(cache, "refs/heads/main", 2.0 * h))
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

///|
test "the repository's caches are held under 7.5 GB, main's never taken for it" {
  let gb = 1000000000L
  assert_eq(repo_cache_cap_bytes, 7500000000L)
  let c : Cache = { id: "0", key: "k-0123456789abcdef", ref_: "refs/heads/main", size: 0L, created: 1.0, accessed: 1.0 }
  let kept = [
    // main's, the biggest and read least recently: stays
    { ..c, id: "1", size: 5L * gb, accessed: 1.0 },
    { ..c, id: "2", ref_: "refs/heads/a", size: 2L * gb, accessed: 2.0 },
    { ..c, id: "3", ref_: "refs/pull/9/merge", size: 1L * gb, accessed: 3.0 },
    // a marker under a megabyte: stays
    { ..c, id: "4", ref_: "refs/heads/b", size: 999999L, accessed: 1.5 },
  ]
  // 8 GB and a little: the branch's read first goes, 6 GB left
  assert_eq(ids_of(over_cap_caches(kept, "refs/heads/main", repo_cache_cap_bytes)), ["2"])
  // without the branch's, 6 GB and a little: nothing more goes
  let under = [kept[0], kept[2], kept[3]]
  assert_eq(ids_of(over_cap_caches(under, "refs/heads/main", repo_cache_cap_bytes)), [])
}

///|
test "an image's version and an apt spec in a key" {
  assert_true(is_image_version("20261111.127.1"))
  assert_true(is_image_version("20261104.0337.1"))
  assert_true(is_image_version("20261104.3"))
  assert_false(is_image_version("20261104"))
  assert_false(is_image_version("2026111.127.1"))
  assert_false(is_image_version("20261111.127.1.2"))
  assert_false(is_image_version("20261111..1"))
  assert_false(is_image_version("5.3.3"))
  assert_true(is_apt_spec("131ce6adc482"))
  assert_false(is_apt_spec("20ba3079a0cbad0f"))
  assert_eq(family_of("mbui-linux-moon-x64-20261111.127.1-909b5cbde5bde107"), Some(("mbui-linux-moon-x64", true)))
  assert_eq(family_of("mbui-linux-moon-x64-11f095d26eab4bed"), Some(("mbui-linux-moon-x64", false)))
  assert_eq(family_of("mbui-ios-moon-20261104.0337.1-6092813ee76aba00"), Some(("mbui-ios-moon", true)))
  assert_eq(
    family_of("mbui-linux-store-app-pkgs-m-20261116.133.1-a19cbafad89f7953"),
    Some(("mbui-linux-store-app-pkgs-m", true)),
  )
  // v1's and v2's apt caches of a name: one family, every one a variant
  assert_eq(family_of("apt-mbui-host-linux-20ba3079a0cbad0f"), Some(("apt-mbui-host-linux", true)))
  assert_eq(family_of("apt-mbui-host-linux-131ce6adc482-bf9c7f2fe9dcddc1"), Some(("apt-mbui-host-linux", true)))
  // a compiler's tag: cc and 12 hex digits, one family with the images' versions it replaced
  assert_true(is_cc_tag("cc1234567890ab"))
  assert_false(is_cc_tag("cc1234567890a"))
  assert_false(is_cc_tag("cc1234567890abc"))
  assert_false(is_cc_tag("cc1234567890aG"))
  assert_false(is_cc_tag("dd1234567890ab"))
  assert_false(is_cc_tag("cc"))
  assert_eq(
    family_of("mbui-linux-store-app-sfapp-m-cc1234567890ab-a19cbafad89f7953"),
    Some(("mbui-linux-store-app-sfapp-m", true)),
  )
  assert_eq(
    family_of("mbui-linux-store-app-sfapp-m-20261116.133.1-a19cbafad89f7953"),
    Some(("mbui-linux-store-app-sfapp-m", true)),
  )
  assert_eq(
    family_of("sf-ui-linux-store-cc1234567890ab-4aa52188713df8eadf6bdb338772e50ada19c5eb"),
    Some(("sf-ui-linux-store", true)),
  )
  // the Mac's launcher, cc and 16 hex digits apart: a kind of its own, not a variant
  assert_eq(
    family_of("mbui-mac-cc-61e77a2d557f8677-00b78fb4840fdc3e"),
    Some(("mbui-mac-cc-61e77a2d557f8677", false)),
  )
  assert_eq(family_of("warp-1.0.21"), None)
  assert_eq(family_of("android-image-34-default-x86_64-2"), None)
  assert_eq(family_of("android-emulator-16428233"), None)
  assert_eq(family_of("moonbit-Linux-X64-github-hosted-20261111.1-e8beca8c9bdab117"), None)
  assert_eq(family_of("pnpm-Linux-20261111.1-81d46fa11a633eee"), None)
}

///|
test "a family's variants go once it moved on, its newest and the fixed ones never" {
  let h = 3600.0
  let mb = 1000000L
  let now = 100.0 * h
  let main = "refs/heads/main"
  let c : Cache = { id: "0", key: "", ref_: main, size: 180L * mb, created: 1.0, accessed: now }
  let ids = fn(kept : Array[Cache]) { ids_of(stale_family_caches(kept, main, now)) }
  // replaced by the plain key: gone 4 hours after its last read, kept before
  let plain = { ..c, id: "p", key: "mbui-linux-moon-x64-11f095d26eab4bed", accessed: now - 60.0 }
  let old = { ..c, id: "v", key: "mbui-linux-moon-x64-20261111.127.1-909b5cbde5bde107", accessed: now - 4.0 * h }
  assert_eq(ids([plain, old]), ["v"])
  assert_eq(ids([plain, { ..old, accessed: now - 4.0 * h + 1.0 }]), [])
  // on another ref, or under a megabyte, or never read: not this rule's
  assert_eq(ids([plain, { ..old, ref_: "refs/heads/feat" }]), [])
  assert_eq(ids([plain, { ..old, size: mb - 1L }]), [])
  assert_eq(ids([plain, { ..old, accessed: 0.0 }]), [])
  // the variant read after the plain key: the newest of its family, kept however long ago
  assert_eq(ids([{ ..plain, accessed: now - 30.0 * h }, { ..old, accessed: now - 20.0 * h }]), [])
  // an image retired, no plain key: gone 12 hours after its last read, once a newer one was read
  let a = { ..c, id: "a", key: "sf-ui-linux-store-20261111.127.1-31f2ead0acde0ce763899fed949abf18ae041228", accessed: now - 12.0 * h }
  let b = { ..c, id: "b", key: "sf-ui-linux-store-20261116.133.1-4aa52188713df8eadf6bdb338772e50ada19c5eb", accessed: now - 60.0 }
  assert_eq(ids([a, b]), ["a"])
  // two images in turn, both read within 12 hours: both kept
  assert_eq(ids([{ ..a, accessed: now - 12.0 * h + 1.0 }, b]), [])
  // the newest of a family is never taken, however long unread
  assert_eq(ids([{ ..b, accessed: now - 50.0 * h }]), [])
  assert_eq(ids([{ ..a, accessed: now - 60.0 * h }, { ..b, accessed: now - 50.0 * h }]), ["a"])
  // the images' stores once the compiler's came: gone 12 hours after their last read, the compiler's kept; and a
  // clang's store once another clang's was read since
  let img_a = { ..c, id: "ia", key: "mbui-linux-store-app-pkgs-m-20261116.133.1-a19cbafad89f7953", accessed: now - 12.0 * h }
  let img_b = { ..c, id: "ib", key: "mbui-linux-store-app-pkgs-m-20261111.370.1-b19cbafad89f7953", accessed: now - 13.0 * h }
  let cc_new = { ..c, id: "cn", key: "mbui-linux-store-app-pkgs-m-cc1234567890ab-c19cbafad89f7953", accessed: now - 60.0 }
  assert_eq(ids([img_a, img_b, cc_new]), ["ia", "ib"])
  assert_eq(ids([{ ..img_a, accessed: now - 12.0 * h + 1.0 }, cc_new]), [])
  let cc_old = { ..c, id: "co", key: "mbui-linux-store-app-pkgs-m-cc0987654321fe-d19cbafad89f7953", accessed: now - 12.0 * h }
  assert_eq(ids([cc_old, cc_new]), ["co"])
  assert_eq(ids([{ ..cc_old, accessed: now }, { ..cc_new, accessed: now - 50.0 * h }]), ["cn"])
  // an apt spec retired and v1's apt cache: gone at 12 hours, the spec read last kept
  let v1 = { ..c, id: "v1", key: "apt-mbui-host-linux-20ba3079a0cbad0f", accessed: now - 17.0 * h }
  let s_old = { ..c, id: "s1", key: "apt-mbui-host-linux-68b46ada6dcd-20ba3079a0cbad0f", accessed: now - 16.0 * h }
  let s_mid = { ..c, id: "s2", key: "apt-mbui-host-linux-875dc52b7221-bf9c7f2fe9dcddc1", accessed: now - 3.0 * h }
  let s_new = { ..c, id: "s3", key: "apt-mbui-host-linux-131ce6adc482-bf9c7f2fe9dcddc1", accessed: now - 60.0 }
  assert_eq(ids([v1, s_old, s_mid, s_new]), ["v1", "s1"])
  // the ones kept by their own name and the toolchains': never
  let fixed = [
    { ..c, id: "w", key: "warp-1.0.21", accessed: now - 90.0 * h },
    { ..c, id: "i", key: "android-image-34-default-x86_64-2", accessed: now - 90.0 * h },
    { ..c, id: "e", key: "android-emulator-16428233", accessed: now - 90.0 * h },
    { ..c, id: "m", key: "moonbit-Linux-X64-github-hosted-20261111.1-e8beca8c9bdab117", accessed: now - 90.0 * h },
    { ..c, id: "m2", key: "moonbit-Linux-X64-github-hosted-20261116.1-e8beca8c9bdab117", accessed: now - 60.0 },
  ]
  assert_eq(ids(fixed), [])
}
