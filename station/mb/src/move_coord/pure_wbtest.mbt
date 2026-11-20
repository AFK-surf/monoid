// The pure parts of move_coord (station/src/move/).

///|
test "an account's item, by what it is known by" {
  assert_eq(account_item_id("p", Some(jo([("share", js("sh"))]))), "share:sh")
  assert_eq(account_item_id("p", Some(jo([("key", js("k"))]))), "key:k")
  assert_eq(account_item_id("p", Some(jo([("own", js("o@A"))]))), "own:o@A")
  assert_eq(account_item_id("p", None), "machine:p")
}

///|
test "a repository's and a job's item" {
  assert_eq(repo_item_id("git@x:y.git"), "repo:git@x:y.git")
  assert_eq(job_item_id(jo([("session", js("s1")), ("name", js("dev"))])), "s1#dev")
}

///|
test "a session's stamp: its last activity, archived or not, its last job" {
  assert_eq(stamp_of(None, None), "")
  assert_eq(
    stamp_of(Some(jo([("lastActiveAt", ji(17)), ("archivedAt", J::Null)])), Some("3/0")),
    "17//3/0",
  )
  assert_eq(
    stamp_of(Some(jo([("lastActiveAt", jn(1.5)), ("archivedAt", ji(9))])), None),
    "1.5/9/",
  )
}

///|
test "a told step under way, by its key" {
  assert_true(is_under(jo([("under", jb(true)), ("told", js("k"))]), "k"))
  assert_true(!is_under(jo([("under", jb(true)), ("told", js("j"))]), "k"))
  assert_true(!is_under(J::Null, "k"))
}

///|
test "a chain of items needing each other round, the rest not on one" {
  let item = (id : String, needs : Array[String]) => jo([
    ("module", js("chats")),
    ("id", js(id)),
    ("label", js(id)),
    ("needs", ja(needs.map(n => jo([("module", js("chats")), ("id", js(n))])))),
  ])
  let cycles = item_cycles([item("a", ["b"]), item("b", ["a"]), item("c", ["a"]), item("d", [])])
  assert_true(cycles.contains("chats a"))
  assert_true(cycles.contains("chats b"))
  assert_true(!cycles.contains("chats c"))
  assert_true(!cycles.contains("chats d"))
  // (the chain named round: from where it starts back to it, a → b → a)
  assert_eq(
    cycles.get("chats a").map(c => c.map(item_id)),
    Some(["a", "b", "a"]),
  )
}

///|
test "vault item ids, owner/workspace parsing and paging" {
  assert_eq(vault_item_id("alice@ex.com"), "vault:alice@ex.com")
  let item = new_item("vault", "\{vault_item_id("alice@ex.com")}@ws-1", "alice's secrets", [])
  assert_eq(vault_of(item), ("alice@ex.com", "ws-1"))
  assert_eq(item_module(item), "vault")
  assert_eq(item_label(item), "alice's secrets")
  // Empty input still yields one empty page; >200 items splits into 200 + remainder.
  assert_eq(pages([]).length(), 1)
  assert_eq(pages([])[0].length(), 0)
  let many = Array::makei(205, i => ji(i))
  let ps = pages(many)
  assert_eq(ps.length(), 2)
  assert_eq(ps[0].length(), 200)
  assert_eq(ps[1].length(), 5)
}

///|
test "settings paths, movable keys and KeptSet persistence" {
  assert_eq(move_path("/data/st", "settings.json"), "/data/st/move/settings.json")
  assert_true(settings_that_move.contains("sandboxes"))
  assert_true(settings_that_move.contains("agentEnv"))
  assert_true(settings_that_move.contains("autoArchiveDays"))
  assert_false(settings_that_move.contains("dataDir"))
  let files : Map[String, String] = {}
  files["/d/move/settings-moved.json"] = "[\"setting:agentEnv\",\"setting:agentEnv\",123,\"setting:maxNudges\"]"
  let disk : Disk = {
    read: p => files.get(p),
    write: async fn(p, s) { files[p] = s },
    append: async fn(p, s) { files[p] = files.get(p).unwrap_or("") + s },
    remove: async fn(p) { files.remove(p) },
    spawn: _ => (),
  }
  let ks = KeptSet::new(disk, "/d/move/settings-moved.json")
  assert_eq(ks.size(), 2)
  assert_true(ks.has("setting:agentEnv"))
  assert_true(ks.has("setting:maxNudges"))
  assert_false(ks.has("setting:sandboxes"))
}

///|
test "roster lookup, station matching and grant owners" {
  let membership = jo([
    (
      "peers",
      ja([
        jo([("id", js("abcdef1234567890")), ("name", js("Studio")), ("mode", js("full"))]),
        jo([("id", js("9999888877776666")), ("name", js("RigOne")), ("mode", js("tasks"))]),
      ]),
    ),
  ])
  assert_true(roster_of(Some(membership), false) is None)
  assert_true(roster_of(None, true) is None)
  let roster = roster_of(Some(membership), true)
  assert_eq(roster.map(r => r.length()), Some(2))
  assert_eq(station_of(roster, "studio", _ => false), Some(("abcdef1234567890", false)))
  assert_eq(station_of(roster, "abcdef12", _ => false), Some(("abcdef1234567890", false)))
  assert_eq(station_of(roster, "abcdef1", _ => false), None)
  assert_eq(station_of(roster, "RigOne", _ => false), Some(("9999888877776666", true)))
  assert_eq(station_of(roster, "Studio", id => id == "abcdef1234567890"), Some(("abcdef1234567890", true)))

  let owners = grant_owners_of([
    jo([("session", js("s1")), ("body", js("{\"request\":{\"owner\":\"a@x\"}}"))]),
    jo([("session", js("s1")), ("body", js("{\"request\":{\"owner\":\"a@x\"}}"))]),
    jo([("session", js("s1")), ("body", js("{\"request\":{\"owner\":\"b@x\"}}"))]),
    jo([("session", js("s2")), ("body", js("{broken"))]),
  ])
  assert_eq(owners.get("s1"), Some(["a@x", "b@x"]))
  assert_eq(owners.get("s2"), None)
}

///|
test "connect ids, short_key, gb formatting, origin_url_of, share_refusal and unanswered_words" {
  assert_eq(connect_item_id("slack-1", "st-a"), "slack-1@st-a")
  assert_eq(connect_item_id("slack-1@st-b", "st-a"), "slack-1@st-b")
  assert_eq(connect_local_of("slack-1@st-a", "st-a"), "slack-1")
  assert_eq(connect_local_of("slack-1@st-b", "st-a"), "slack-1@st-b")
  assert_eq(short_key("chat:c-123"), "c-123")
  assert_eq(short_key("c-123"), "c-123")
  assert_eq(gb(0.0), "0.0 GB")
  assert_eq(gb(1073741824.0 * 2.5), "2.5 GB")
  let git_cfg = "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = git@github.com:AFK-surf/monoid.git\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n"
  assert_eq(origin_url_of(git_cfg), Some("git@github.com:AFK-surf/monoid.git"))
  assert_eq(origin_url_of("[core]\n\tbare = true\n"), None)
  assert_true(
    share_refusal(Some(jo([("share", jo([("borrowed", jb(true))]))]))) is Some(_),
  )
  assert_true(
    share_refusal(Some(jo([("runtime", js("grok")), ("access", jo([("kind", js("subscription"))]))]))) is Some(_),
  )
  assert_true(
    share_refusal(Some(jo([("runtime", js("claude")), ("access", jo([("kind", js("apiKey"))]))]))) is None,
  )
  assert_true(unanswered_words("request timed out"))
  assert_true(unanswered_words("connection was reset by peer"))
  assert_false(unanswered_words("permission denied"))
}
