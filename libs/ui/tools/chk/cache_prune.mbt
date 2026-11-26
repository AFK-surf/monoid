// chk cache-prune [--dry-run]: the Actions caches a newer one of the same kind has replaced, deleted (cache-prune.yml;
// GH_REPO=owner/name, gh logged in or GH_TOKEN with actions: write).
//
// A repository has 10 GB of caches; past that GitHub evicts the least recently used, and what went first were the
// caches read seldom that jobs cannot do without (WARP, the emulator's system images, MoonBit: "no WARP 1.0.21 in the
// Actions cache", runs 39536847651, 39731343052). A cache saved once per commit, run or content is keyed
// <kind>-<id>, the id a sha, a content's hash (16 hex digits or more) or a run's <id>-<attempt>; a restore by
// restore-keys takes the newest of a kind on its ref (then main's), so the older ones of a kind on a ref are never read
// again: kept is the newest of each kind on each live ref, the rest deleted (one under a megabyte left: it frees
// nothing). A deleted branch's caches cannot be restored by another branch, so all of its caches are removed once
// they have not been created or read for 5 minutes, and a live branch's once not read for 2 hours. Pull request and
// other refs keep their own existing rules. Of the default branch's, a kind that is a variant of a family (an image's
// version or an apt spec in its key) goes once its family has moved on (`stale_family_caches`).
// What is kept after all that is held under `repo_cache_cap_bytes`: 15 branches pushed within 12 hours kept 15.8 GB,
// the repository 23.7 GB (2026-11-17, run 44076658048 deleted none of its 152), and GitHub's eviction took main's
// seldom read ones again (warp-1.0.21, android-image, natives-shell-apple, mbui-tool-*). Over it, the caches of refs
// other than the default branch (a branch's, a pull request's) go, least recently read first, till it holds: such a
// branch's next push restores main's by restore-keys, as after 2 hours idle. The default branch's are never taken
// for it, nor one under a megabyte. Held under 9 GB, the repository still came to 12.15 GB between two prunes (191
// caches, 2026-11-17) and GitHub evicted main's mbui-moon-build-app and mbui-mac-moon: the cap is 7.5 GB now, and the
// grace of a deleted branch's and an idle one's caches shorter (30 minutes and 12 hours held 3-4 GB of the branches
// merged and deleted in a busy hour).
// (A list of the kinds by name, as .github/cache_prune.py had, missed each new one: on 2026-10-22 mbui-apk-<sha>,
// android-lint-main-<sha>, android-build-main-<sha> and the mbui-linux-store-… ones were 4 GB of the 22.)
// setup-gradle's parts of a Gradle home (gradle-transforms-v1-<hash>, gradle-dependencies-v1-…: by their content,
// each read as a home that names it is restored) are deleted when read 30 minutes or more before the earliest last
// read of the homes kept on their ref (each job's newest): a part one of them names is read each time it is (a day's
// were 6 GB on 2026-10-22, when the rule was a day since they were read). Measured against the last read of a part
// of their kind instead, those of a job run less often went: check-android's home then named parts no longer there,
// its Gradle cold (2026-10-22, 39752751241).

///|
struct Cache {
  id : String
  key : String
  ref_ : String
  size : Int64
  created : Double
  accessed : Double
}

///|
let stale_parts_s : Double = 30.0 * 60.0

///|
let deleted_head_grace_s : Double = 5.0 * 60.0

///|
fn is_hex(s : String) -> Bool {
  s.length() > 0 &&
  s.iter().all(fn(c) { (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') })
}

///|
fn is_digits(s : String) -> Bool {
  s.length() > 0 && s.iter().all(fn(c) { c >= '0' && c <= '9' })
}

///|
/// setup-gradle's part of a home: gradle-<name>-v1-<32 hex digits>
fn is_gradle_part(key : String) -> Bool {
  if !key.has_prefix("gradle-") || key.has_prefix("gradle-home-") {
    return false
  }
  let parts = key.split("-").map(fn(p) { p.to_owned() }).to_array()
  let n = parts.length()
  n >= 4 && parts[n - 2] == "v1" && parts[n - 1].length() == 32 && is_hex(parts[n - 1])
}

///|
/// A rolling cache's kind (its key without the id), or None for one kept by its own name
fn kind_of(key : String) -> String? {
  let parts = key.split("-").map(fn(p) { p.to_owned() }).to_array()
  let n = parts.length()
  if n >= 2 && parts[n - 1].length() >= 16 && is_hex(parts[n - 1]) {
    // scripts/native.ts keys a part by 24-hex-digit hashes, one per part in it (natives-<os>-<arch>-<shell>-<engine>
    // and -<shell>-<engine>-<ghostty-vt>): each is the id, or each build kept a kind of its own (28 of them, 807 MB on
    // main, 2026-11-19); how many there are stays in the kind, as `<24>`, for the two- and three-part caches are read
    // by different jobs. A 16-digit one before the last stays in the kind (mbui-mac-cc-<launcher>-<inputs>).
    let mut end = n - 1
    while end > 1 && parts[end - 1].length() == 24 && is_hex(parts[end - 1]) {
      end -= 1
    }
    let mut kind = parts[0:end].join("-")
    for _ in end..<(n - 1) {
      kind = kind + "-<24>"
    }
    return Some(kind)
  }
  if n >= 3 && is_digits(parts[n - 1]) && is_digits(parts[n - 2]) && parts[n - 2].length() >= 6 {
    return Some(parts[0:n - 2].join("-"))
  }
  None
}

///|
/// 2026-10-22T05:37:59.731503Z: seconds since 1970
fn iso_s(t : String) -> Double {
  let num = fn(a : Int, b : Int) -> Int {
    let mut v = 0
    for i in a..<b {
      if i < t.length() {
        let c = t.code_unit_at(i).to_int()
        if c >= 48 && c <= 57 {
          v = v * 10 + (c - 48)
        }
      }
    }
    v
  }
  if t.length() < 19 {
    return 0.0
  }
  let y0 = num(0, 4)
  let m = num(5, 7)
  let d = num(8, 10)
  // days from 1970-01-01 (Howard Hinnant's days_from_civil)
  let y = if m <= 2 { y0 - 1 } else { y0 }
  let era = (if y >= 0 { y } else { y - 399 }) / 400
  let yoe = y - era * 400
  let mp = if m > 2 { m - 3 } else { m + 9 }
  let doy = (153 * mp + 2) / 5 + d - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  let days = era * 146097 + doe - 719468
  days.to_double() * 86400.0 +
  (num(11, 13) * 3600 + num(14, 16) * 60 + num(17, 19)).to_double()
}

///|
/// How many times a call of GitHub's API is made before it counts as failed: the API answers a 5xx now and then
/// ("gh: Server Error (HTTP 502)" listing the branches, run 43977844748), and this runs over a hundred times a day.
let gh_tries : Int = 3

///|
/// `gh <args>`'s lines, made by `run` up to `gh_tries` times with `pause` between; None when every one failed, which
/// lets nothing be deleted.
fn gh_lines_by(
  args : String,
  run : (String) -> String?,
  pause : () -> Unit,
) -> Array[String]? {
  for i in 0..<gh_tries {
    if i > 0 {
      pause()
    }
    match run("gh " + args) {
      Some(o) =>
        return Some(
          o
          .split("\n")
          .map(fn(l) { l.to_owned() })
          .filter(fn(l) { l.length() > 0 })
          .to_array(),
        )
      None => ()
    }
  }
  None
}

///|
fn gh_pause() -> Unit {
  ignore(@sys.run_out("sleep 2"))
}

///|
fn gh_lines(args : String) -> Array[String]? {
  gh_lines_by(args, @sys.run_out, gh_pause)
}

///|
/// A cache's delete, made by `delete` up to `gh_tries` times with `pause` between while it is `there`: None once it is
/// done or gone, else the last answer. (Gone already, between the list and here: GitHub's own eviction, run
/// 39606378560; or a 5xx for a delete that was done all the same, run 39620407496: what decides is whether it is
/// still there.)
fn delete_cache_by(
  delete : () -> String,
  there : () -> Bool,
  pause : () -> Unit,
) -> String? {
  let mut r = ""
  for i in 0..<gh_tries {
    if i > 0 {
      pause()
    }
    r = delete()
    if r.contains("exit=0") || r.contains("HTTP 404") || !there() {
      return None
    }
  }
  Some(r)
}

///|
/// A deleted branch's old caches are not available to live branches. Keep recent, malformed and non-branch refs.
fn deleted_head_cache(c : Cache, heads : Map[String, Bool], now : Double) -> Bool {
  c.ref_.has_prefix("refs/heads/") &&
  !heads.contains(c.ref_) &&
  c.created > 0.0 && c.accessed > 0.0 &&
  now - c.created >= deleted_head_grace_s && now - c.accessed >= deleted_head_grace_s
}

///|
/// A live branch's caches not read for so long: a branch pushed again after it restores main's by restore-keys, as a
/// new one does. Kept till it is gone, the caches of the 70 branches besides main held 5.4 GB
/// of the 10 on 2026-11-15, most of it unread for 12-24 hours, and GitHub evicted the emulator's build, read each
/// scheduled mbui-ci run: android-streams-real, android-devices and android-oldest failed with no emulator (43673780626).
let idle_branch_s : Double = 2.0 * 3600.0

///|
/// A branch's cache (not the default branch's) not read for `idle_branch_s`
fn idle_branch_cache(c : Cache, default_head : String, now : Double) -> Bool {
  c.ref_.has_prefix("refs/heads/") &&
  c.ref_ != default_head &&
  c.accessed > 0.0 &&
  now - c.accessed >= idle_branch_s
}

///|
/// The most the caches kept may hold: GitHub's 10 GB less two and a half for what runs save while this one has not
/// run again (a prune each quarter hour, and after each of main's runs).
let repo_cache_cap_bytes : Int64 = 7_500_000_000L

///|
/// What goes of `kept` to hold it under `cap`: caches of refs other than `default_head` and live `refs/heads/release/*`
/// branches, a megabyte or more, least recently read first (then the oldest, then by id), till what is left is at or
/// under `cap`. None of the default branch's or live release branches', however far over it alone is: a nightly release
/// branch diverges ~24 h from main and builds `release_light` (-O0) units absent from main's 3 h store, so deleting its
/// store forces every push on it to recompile cold; deleted or idle (>2 h) release branches are still pruned above.
fn over_cap_caches(kept : Array[Cache], default_head : String, cap : Int64) -> Array[Cache] {
  let mut bytes = kept.fold(init=0L, fn(a, c) { a + c.size })
  let out : Array[Cache] = []
  if bytes <= cap {
    return out
  }
  let others = kept.filter(fn(c) {
    c.ref_ != default_head &&
    !c.ref_.has_prefix("refs/heads/release/") &&
    c.size >= 1000000L
  })
  others.sort_by(fn(a, b) {
    let by_read = a.accessed.compare(b.accessed)
    if by_read != 0 {
      return by_read
    }
    let by_made = a.created.compare(b.created)
    if by_made != 0 {
      return by_made
    }
    let by_len = a.id.length().compare(b.id.length())
    if by_len != 0 { by_len } else { a.id.compare(b.id) }
  })
  for c in others {
    if bytes <= cap {
      break
    }
    out.push(c)
    bytes -= c.size
  }
  out
}

///|
/// A runner image's version in a key: 20261111.127.1, 20261104.0337.1 (`ImageVersion`, YYYYMMDD.N or YYYYMMDD.N.N)
fn is_image_version(s : String) -> Bool {
  let parts = s.split(".").map(fn(p) { p.to_owned() }).to_array()
  parts.length() >= 2 &&
  parts.length() <= 3 &&
  parts[0].length() == 8 &&
  parts.iter().all(is_digits)
}

///|
/// A Linux runner's compiler in a key: cc and 12 hex digits (mbui-check.yml's IMG, of clang and the C headers it preprocesses)
fn is_cc_tag(s : String) -> Bool {
  s.length() == 14 && s.has_prefix("cc") && is_hex(s)
}

///|
/// What a store of an image's or a compiler's is kept apart by: an image's version or a compiler's tag
fn is_store_variant(s : String) -> Bool {
  is_image_version(s) || is_cc_tag(s)
}

///|
/// An apt cache's spec, 12 hex digits (apt-<name>-<spec>-<inputs>)
fn is_apt_spec(s : String) -> Bool {
  s.length() == 12 && is_hex(s)
}

///|
/// A rolling cache's family and whether it is a variant of it: an apt cache's kind less its spec (v1's
/// apt-<name>-<inputs> and v2's apt-<name>-<spec>-<inputs> both apt-<name>), a kind naming an image's version or a
/// compiler's tag less it (mbui-linux-moon-x64-20261111.127.1: mbui-linux-moon-x64; mbui-linux-store-app-pkgs-m-
/// cc0123456789ab and the -m-20261116.133.1 it replaced: mbui-linux-store-app-pkgs-m, so the images' stores go 12 hours
/// after the compiler's was first read, and a clang's once another's took its place); any other kind is its own
/// family, not a variant. None
/// for a cache kept by its own name.
fn family_of(key : String) -> (String, Bool)? {
  if key.has_prefix("moonbit-") || key.has_prefix("pnpm-") {
    return None
  }
  guard kind_of(key) is Some(k) else { return None }
  let parts = k.split("-").map(fn(p) { p.to_owned() }).to_array()
  if k.has_prefix("apt-") {
    let n = parts.length()
    let fam = if n >= 2 && is_apt_spec(parts[n - 1]) {
      parts[0:n - 1].join("-")
    } else {
      k
    }
    return Some((fam, true))
  }
  if parts.iter().any(is_store_variant) {
    return Some((parts.filter(fn(p) { !is_store_variant(p) }).join("-"), true))
  }
  Some((k, false))
}

///|
/// The default branch's variants of a family no job reads any more, kept by `kind_of` as kinds of their own: those
/// keyed by an image's version once the plain key replaced them (mbui-linux-moon-x64-2026111* when
/// mbui-linux-moon-x64 came), by an image retired, and an apt cache of a spec retired. One goes when a newer of its
/// family was read since, and it has not been read for 4 hours with its family's plain key read since, or for 12
/// hours (two images in turn both read within that: both kept). The family's most recently read is never one of
/// them, nor one under a megabyte (2.0 GB of main's 12.89, 2026-11-19).
fn stale_family_caches(
  kept : Array[Cache],
  default_head : String,
  now : Double,
) -> Array[Cache] {
  let h = 3600.0
  let seen : Array[(Cache, String, Bool)] = []
  let max_read : Map[String, Double] = Map([])
  let plain_read : Map[String, Double] = Map([])
  for c in kept {
    if c.ref_ != default_head || c.size < 1000000L || c.accessed <= 0.0 {
      continue
    }
    guard family_of(c.key) is Some((fam, variant)) else { continue }
    seen.push((c, fam, variant))
    if max_read.get(fam).unwrap_or(0.0) < c.accessed {
      max_read[fam] = c.accessed
    }
    if !variant && plain_read.get(fam).unwrap_or(0.0) < c.accessed {
      plain_read[fam] = c.accessed
    }
  }
  let out : Array[Cache] = []
  for s in seen {
    let (c, fam, variant) = s
    if !variant || c.accessed >= max_read.get(fam).unwrap_or(0.0) {
      continue
    }
    let idle = now - c.accessed
    let replaced = plain_read.get(fam).unwrap_or(0.0) > c.accessed && idle >= 4.0 * h
    if replaced || idle >= 12.0 * h {
      out.push(c)
    }
  }
  out
}

///|
/// A Git ref can contain shell metacharacters, including single quotes.
fn shell_arg(s : String) -> String {
  "'" + s.replace(old="'", new="'\\''") + "'"
}

///|
/// Recheck a missing ref: branch creation/deletion while listing pages can make one live branch fall between pages.
/// None means GitHub did not give a definite answer; never turn an API failure into permission to delete.
fn head_missing(repo : String, ref_ : String) -> Bool? {
  let names = repo.split("/").map(fn(p) { p.to_owned() }).to_array()
  if names.length() != 2 || names[0] == "" || names[1] == "" {
    return None
  }
  let query = "query($owner:String!,$name:String!,$ref:String!){repository(owner:$owner,name:$name){ref(qualifiedName:$ref){name}}}"
  let jq = "if ((.errors // []) | length) > 0 or .data.repository == null then \"error\" elif .data.repository.ref == null then \"missing\" else \"present\" end"
  let args = "api graphql -f " + shell_arg("owner=" + names[0]) + " -f " + shell_arg("name=" + names[1]) +
    " -f " + shell_arg("ref=" + ref_) + " -f " + shell_arg("query=" + query) + " --jq " + shell_arg(jq)
  match gh_lines(args) {
    Some(lines) if lines.length() == 1 && lines[0] == "missing" => Some(true)
    Some(lines) if lines.length() == 1 && lines[0] == "present" => Some(false)
    _ => None
  }
}

///|
fn still_there(repo : String, c : Cache) -> Bool {
  // Pass the ref as a query field, so quotes and URL metacharacters in a branch name stay part of the ref.
  let args = "api --paginate -X GET " + shell_arg("repos/" + repo + "/actions/caches") +
    " -f per_page=100 -f " + shell_arg("ref=" + c.ref_) + " -q '.actions_caches[].id'"
  match gh_lines(args) {
    Some(ids) => ids.contains(c.id)
    None => true
  }
}

///|
fn cache_prune(args : Array[String]) -> Int {
  let dry = args.contains("--dry-run")
  let repo = match @sys.getenv("GH_REPO") {
    Some(r) if r.length() > 0 => r
    _ =>
      match @sys.getenv("GITHUB_REPOSITORY") {
        Some(r) => r
        None => {
          @sys.eprintln("chk cache-prune: GH_REPO=owner/name")
          return 2
        }
      }
  }
  // A failed or incomplete branch listing must never make live branches look deleted.
  let default_head = match gh_lines("api repos/\{repo} -q .default_branch") {
    Some(l) if l.length() == 1 => "refs/heads/" + l[0]
    _ => {
      @sys.eprintln("chk cache-prune: the default branch (gh api) failed")
      return 1
    }
  }
  let branch_names = match gh_lines("api --paginate 'repos/\{repo}/branches?per_page=100' -q '.[].name'") {
    Some(l) => l
    None => {
      @sys.eprintln("chk cache-prune: the branches' list (gh api) failed")
      return 1
    }
  }
  let heads : Map[String, Bool] = Map([])
  for name in branch_names {
    heads["refs/heads/" + name] = true
  }
  if !heads.contains(default_head) {
    @sys.eprintln("chk cache-prune: the branches' list has no default branch")
    return 1
  }
  let now = match @sys.run_out("date -u +%s") {
    Some(s) if is_digits(trim(s)) => num_of(trim(s))
    _ => {
      @sys.eprintln("chk cache-prune: the current time is unavailable")
      return 1
    }
  }
  let lines = match
    gh_lines(
      "api --paginate 'repos/\{repo}/actions/caches?per_page=100' -q '.actions_caches[]|[.id,.key,.ref,.size_in_bytes,.created_at,.last_accessed_at]|@tsv'",
    ) {
    Some(l) => l
    None => {
      @sys.eprintln("chk cache-prune: the caches' list (gh api) failed")
      return 1
    }
  }
  let caches : Array[Cache] = []
  for l in lines {
    let f = l.split("\t").map(fn(p) { p.to_owned() }).to_array()
    if f.length() < 6 {
      continue
    }
    caches.push({
      id: f[0],
      key: f[1],
      ref_: f[2],
      size: num_of(f[3]).to_int64(),
      created: iso_s(f[4]),
      accessed: iso_s(f[5]),
    })
  }
  caches.sort_by(fn(a, b) { b.created.compare(a.created) })
  // the homes kept (each job's newest) on each ref, and the earliest of their last reads: a part one of them names is
  // read with it, so read since then (less a while); each kind of part's last read too, for a ref with no home
  let homes_read : Map[String, Double] = Map([])
  let home_seen : Map[String, Bool] = Map([])
  let last_read : Map[String, Double] = Map([])
  for c in caches {
    if is_gradle_part(c.key) {
      let s = part_slot(c)
      if last_read.get(s).unwrap_or(0.0) < c.accessed {
        last_read[s] = c.accessed
      }
    } else if c.key.has_prefix("gradle-home-") {
      let slot = kind_of(c.key).unwrap_or(c.key) + "\n" + c.ref_
      if !home_seen.contains(slot) {
        home_seen[slot] = true
        match homes_read.get(c.ref_) {
          Some(t) if t <= c.accessed => ()
          _ => homes_read[c.ref_] = c.accessed
        }
      }
    }
  }
  let newest : Map[String, Bool] = Map([])
  let missing_heads : Map[String, Bool] = Map([])
  let gone : Array[Cache] = []
  for c in caches {
    if deleted_head_cache(c, heads, now) {
      let missing = match missing_heads.get(c.ref_) {
        Some(m) => m
        None =>
          match head_missing(repo, c.ref_) {
            Some(m) => {
              missing_heads[c.ref_] = m
              m
            }
            None => {
              @sys.eprintln("chk cache-prune: could not confirm branch \{c.ref_}")
              return 1
            }
          }
      }
      if missing {
        gone.push(c)
        continue
      }
    }
    if idle_branch_cache(c, default_head, now) {
      gone.push(c)
      continue
    }
    if is_gradle_part(c.key) {
      let since = match homes_read.get(c.ref_) {
        Some(t) => t
        None => last_read.get(part_slot(c)).unwrap_or(c.accessed)
      }
      if since - c.accessed > stale_parts_s {
        gone.push(c)
      }
      continue
    }
    match kind_of(c.key) {
      Some(k) => {
        let slot = k + "\n" + c.ref_
        // (one under a megabyte left: it frees nothing, and some small ones are markers looked up by their exact
        // key, mbui-android-refs-same-<inputs>)
        if newest.contains(slot) {
          if c.size >= 1000000L {
            gone.push(c)
          }
        } else {
          newest[slot] = true
        }
      }
      None => ()
    }
  }
  let going : Map[String, Bool] = Map([])
  for c in gone {
    going[c.id] = true
  }
  for c in stale_family_caches(
    caches.filter(fn(c) { !going.contains(c.id) }),
    default_head,
    now,
  ) {
    gone.push(c)
    going[c.id] = true
  }
  let kept = caches.filter(fn(c) { !going.contains(c.id) })
  for c in over_cap_caches(kept, default_head, repo_cache_cap_bytes) {
    gone.push(c)
  }
  let mut freed = 0L
  for c in gone {
    say(
      "\{if dry { "would delete" } else { "delete" }} \{c.key} (\{c.ref_}, \{c.size / 1000000L} MB)",
    )
    if !dry {
      let failed = delete_cache_by(
        fn() {
          @sys.run_out(
            "gh api -X DELETE repos/\{repo}/actions/caches/\{c.id} 2>&1; echo \"exit=$?\"",
          ).unwrap_or("exit=1")
        },
        fn() { still_there(repo, c) },
        gh_pause,
      )
      if failed is Some(r) {
        @sys.eprintln("chk cache-prune: deleting \{c.key}: \{trim(r)}")
        return 1
      }
    }
    freed += c.size
  }
  let total = caches.fold(init=0L, fn(a, c) { a + c.size })
  say(
    "\{gone.length()} of \{caches.length()} caches, \{freed / 1000000L} MB of \{total / 1000000L} MB",
  )
  0
}

///|
/// A part's kind (gradle-transforms-v1, …) and ref
fn part_slot(c : Cache) -> String {
  let parts = c.key.split("-").map(fn(p) { p.to_owned() }).to_array()
  parts[0:parts.length() - 1].join("-") + "\n" + c.ref_
}
