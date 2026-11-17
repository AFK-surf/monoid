// The pure parts, as the TypeScript (src/move/) says them; test/mb-move-coord.test.ts holds the rest to it through the
// program, these the values it gave (node, the same inputs).

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
