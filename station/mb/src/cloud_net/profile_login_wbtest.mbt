// FB-44: the managers told which profile's login is over (cloud/notify.ts `notifyProfileLogin`), once in four hours a
// workspace, and at once again after it was good.

///|
test "a profile's login-over notice: managers, failed, its words, cooled down a workspace, cleared when good again" {
  let told : Map[String, Int64] = {}
  let first = profile_login_notice(told, "ws1", "sh-1", "Claude A", "Claude Code", "Host A", 1000L, "words")
  guard first is Some(n) else { fail("not told") }
  assert_eq(n.value("audience"), Some(Json::string("managers")))
  assert_eq(n.value("kind"), Some(Json::string("failed")))
  assert_eq(n.value("session"), Some(Json::string("profile:sh-1")))
  assert_eq(n.value("title"), Some(Json::string("Host A")))
  assert_eq(n.value("text"), Some(Json::string("words")))
  assert_eq(n.value("to"), Some(Json::array([])))
  assert_true(profile_login_notice(told, "ws1", "sh-1", "Claude A", "Claude Code", "Host A", 1000L + 3_600_000L, "words") is None)
  assert_true(profile_login_notice(told, "ws2", "sh-1", "Claude A", "Claude Code", "Host A", 1001L, "words") is Some(_))
  assert_true(profile_login_notice(told, "ws1", "sh-2", "Claude B", "Claude Code", "Host A", 1002L, "words") is Some(_))
  assert_true(profile_login_notice(told, "ws1", "sh-1", "Claude A", "Claude Code", "Host A", 1000L + profile_login_cooldown_ms, "words") is Some(_))
  profile_login_clear(told, "sh-1")
  assert_true(profile_login_notice(told, "ws1", "sh-1", "Claude A", "Claude Code", "Host A", 1000L + profile_login_cooldown_ms + 1L, "words") is Some(_))
  assert_true(profile_login_notice(told, "ws1", "sh-2", "Claude B", "Claude Code", "Host A", 2000L, "words") is None)
}
