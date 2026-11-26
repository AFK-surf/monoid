///|
test "topic_policy_gen covers all 125 protocol topics and rejects unknown names" {
  let all_topics : Array[String] = [
    "accounts", "workspaces", "workspace", "link", "overview", "sessions", "session", "live", "host", "memory",
    "presets", "profilePace", "stationMove", "net", "way", "threads", "thread", "letters", "chatRows", "slackApp",
    "jobs", "jobLog", "machineLogins", "machineLogin", "machineLoginScreen", "loginSessions", "admin", "adminList",
    "adminItem", "adminOverview", "adminRelays", "chats", "projects", "project", "tags", "chatRow", "stations",
    "station", "stationPart", "profiles", "profile", "profilesOverview", "connects", "connect", "connectCandidates",
    "chat", "history", "agentCard", "stationNet", "stationDiag", "status", "notices", "connection", "draft",
    "composer", "notify", "chatSearch", "archivedRows", "archive", "search", "stationSearch", "linkPreview",
    "filePeek", "messagePeek", "newChat", "preset", "otherPresets", "boardDrafts", "shareIn", "pick", "chatJobs",
    "chatLetters", "chatFeedback", "chatThings", "chatOutline", "chatSubchats", "imageNear", "longJobs",
    "stationUsage", "stationRates", "usage", "agentRates", "fleet", "railCard", "stationUpdates", "settings",
    "stationResources", "resources", "job", "drive", "drivePlace", "prefs", "doing", "adbShare", "adbCard", "rigs",
    "devices", "previewLoad", "slackTokens", "connectFlow", "decisionForm", "policyForm", "agentEnvForm",
    "profileFlow", "changelog", "releases", "fonts", "workspaceMarks", "workspaceWays", "lock", "joinable",
    "memberships", "screens", "terminals", "screenCard", "terminalCard", "lockDraft", "lockPrompts", "vaults",
    "vaultItems", "driveTransfers", "driveBrowse", "filesTabs", "downloads", "vaultUses",
  ]
  assert_eq(all_topics.length(), 125)
  let empty = Json::object({})
  for name in all_topics {
    assert_true(topic_policy_known(name, empty))
  }
  assert_false(topic_policy_known("", empty))
  assert_false(topic_policy_known("unknownTopic", empty))
  assert_false(topic_policy_known("toString", empty))
}

///|
test "topic_policy_gen matches lasting, home_lasting, views_kept, chat, and q/query branches" {
  let empty = Json::object({})
  let with_q = Json::object({ "scope": Json::string("w1"), "q": Json::string("abc") })
  let with_empty_q = Json::object({ "scope": Json::string("w1"), "q": Json::string("") })
  let with_query = Json::object({ "scope": Json::string("w1"), "query": Json::string("abc") })
  let with_empty_query = Json::object({ "scope": Json::string("w1"), "query": Json::string("") })

  let expected_lasting : Array[String] = [
    "workspace", "stations", "stationNet", "screens", "terminals", "profiles", "connects", "vaults", "usage",
    "archive", "chats", "longJobs", "changelog", "stationUpdates",
  ]
  assert_eq(expected_lasting.length(), 14)
  for name in expected_lasting {
    assert_true(topic_policy_lasting(name, empty))
    assert_false(topic_policy_lasting(name, with_q))
    assert_false(topic_policy_lasting(name, with_empty_q))
    assert_false(topic_policy_lasting(name, with_query))
    assert_true(topic_policy_lasting(name, with_empty_query))
    assert_eq(topic_kept_by(name, empty, true), 64)
    assert_eq(topic_kept_by(name, empty, false), 64)
    assert_eq(topic_kept_by(name, with_q, true), 0)
    assert_eq(topic_kept_by(name, with_query, true), 0)
    assert_false(topic_shown_kept(name))
  }

  for name in ["chats", "longJobs", "changelog"] {
    assert_true(home_lasting_of(name))
  }
  assert_false(home_lasting_of("workspace"))
  assert_false(home_lasting_of("chat"))

  let expected_views : Array[(String, Int)] = [
    ("agentRates", 4),
    ("chatRow", 32),
    ("chatJobs", 16),
    ("agentCard", 16),
    ("railCard", 16),
    ("station", 16),
    ("stationPart", 24),
    ("profile", 16),
    ("connect", 16),
    ("connectCandidates", 8),
    ("pick", 12),
    ("drivePlace", 24),
    ("chatOutline", 8),
    ("projects", 8),
    ("project", 16),
    ("tags", 8),
  ]
  assert_eq(expected_views.length(), 16)
  for kv in expected_views {
    let (name, cap) = kv
    assert_false(topic_policy_lasting(name, empty))
    assert_eq(topic_kept_by(name, empty, true), cap)
    assert_eq(topic_kept_by(name, empty, false), 0)
    assert_eq(topic_kept_by(name, with_q, true), 0)
    assert_eq(topic_kept_by(name, with_query, true), 0)
    assert_eq(topic_kept_by(name, with_empty_query, true), cap)
    assert_true(topic_shown_kept(name))
    assert_true(topic_policy_show_kept(name, empty, true))
    assert_false(topic_policy_show_kept(name, empty, false))
    assert_false(topic_policy_show_kept(name, with_q, true))
    assert_false(topic_policy_show_kept(name, with_query, true))
  }

  assert_eq(topic_kept_by("chat", empty, true), 8)
  assert_eq(topic_kept_by("chat", empty, false), 4)
  assert_false(topic_shown_kept("chat"))
  assert_false(topic_policy_lasting("chat", empty))

  assert_eq(kept_most_by(true), 96)
  assert_eq(kept_most_by(false), 64)

  for name in ["accounts", "workspaces", "chatSearch", "search", "chatSubchats", "profilesOverview", "notify"] {
    assert_false(topic_policy_lasting(name, empty))
    assert_eq(topic_kept_by(name, empty, true), 0)
    assert_false(topic_shown_kept(name))
  }
}
