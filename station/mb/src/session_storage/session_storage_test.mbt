///|
test "a thread's address read back" {
  assert_eq(@session_storage.parse_thread_address(" C123/1700000000.000100 "), Some(("C123", "1700000000.000100")))
  assert_eq(@session_storage.parse_thread_address("oc_ab/omt_x1"), Some(("oc_ab", "omt_x1")))
  assert_eq(@session_storage.parse_thread_address("0123456789abcdef/0123456789abcdef"), None)
  assert_eq(
    @session_storage.parse_thread_address("s_0123456789abcdef01234567/t_0123456789abcdef"),
    Some(("s_0123456789abcdef01234567", "t_0123456789abcdef")),
  )
  assert_eq(@session_storage.parse_thread_address("c1/1.2"), None)
  assert_eq(@session_storage.parse_thread_address("C1/12"), None)
}

///|
test "times as toISOString writes them" {
  assert_eq(@session_storage.iso(0.0), "1970-01-01T00:00:00.000Z")
  assert_eq(@session_storage.iso(1800000000000.0), "2027-01-15T08:00:00.000Z")
  assert_eq(@session_storage.iso(-1.0), "1969-12-31T23:59:59.999Z")
}

///|
test "links named by their session, station and workspace" {
  assert_eq(@session_storage.linked_session("https://app/o/W1/st-1/a%2Fb+c) more"), Some(("a/b+c", None)))
  assert_eq(@session_storage.linked_session("x?history=h%41&entry=12#"), Some(("hA", Some(12))))
  assert_eq(@session_storage.linked_session("plain"), None)
  assert_eq(@session_storage.linked_station("https://x/w/W2/s/st-9/chats/kk"), Some("st-9"))
  assert_eq(@session_storage.linked_workspace("https://app/o/W1/st-1/k"), Some("W1"))
  assert_eq(@session_storage.split_n("a/b/c/d", "/", 3), ["a", "b", "c/d"])
  assert_eq(@session_storage.percent_decode("a%20b+c%e4%b8%ad%zz"), "a b c中%zz")
}

///|
test "git addresses cloned and kept without their passwords" {
  assert_eq(@session_storage.clone_url(Some(Json::string("owner/name.git"))), "https://github.com/owner/name.git")
  assert_eq(@session_storage.clone_url(Some(Json::string("git@github.com:a/b.git"))), "git@github.com:a/b.git")
  assert_eq((try @session_storage.clone_url(Some(Json::string("file:///etc"))) catch { _ => "refused" }), "refused")
  assert_eq((try @session_storage.clone_url(Some(Json::string("ssh://u@-x/y"))) catch { _ => "refused" }), "refused")
  assert_eq(@session_storage.safe_url("https://user:tok@github.com/a/b.git"), "https://github.com/a/b.git")
  assert_eq(@session_storage.safe_url("ssh://git:pw@h/x"), "ssh://git@h/x")
  assert_eq(@session_storage.repo_name("git@github.com:a/b.git"), "github.com/a/b")
  assert_eq(@session_storage.repo_name("ssh://git@h.com/a/b/"), "h.com/a/b")
  assert_eq(@session_storage.origin_in("[remote \"origin\"]\n\turl = https://h/x/y\n"), Some("h/x/y"))
}

///|
test "a note's mentions" {
  let people = [
    Json::object({ "id": Json::string("U1"), "name": Json::string("Ann") }),
    Json::object({ "id": Json::string("U2"), "name": Json::string("Ann Lee") }),
  ]
  assert_eq(@session_storage.mentioned("hi @Ann Lee and @Ann, @Annie x@Ann", people, id => "<\{id}>"), "hi <U2> and <U1>, @Annie x@Ann")
}

///|
test "a policy checked and what changed said" {
  let p = @session_storage.default_policy
  assert_eq(@session_storage.change_summary(p, p), "")
  let given : Json = {
    "policy": "p",
    "options": [{ "name": "a", "archive": true }, { "id": "option_2", "name": "b", "archive": false }, { "name": "c", "archive": false }],
  }
  let checked = @session_storage.checked_policy(Some(given))
  assert_eq(checked.options.map(o => o.id), ["option_1", "option_2", "option_3"])
  assert_eq((try @session_storage.checked_policy(Some({ "policy": " " })).policy catch { e => @session_storage.message_of(e) }), "策略不能是空的")
}
