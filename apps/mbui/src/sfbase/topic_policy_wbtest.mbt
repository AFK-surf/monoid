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
    "workspace", "workspaces", "stations", "stationNet", "screens", "terminals", "profiles", "connects", "usage",
    "archive", "chats", "longJobs", "changelog", "stationUpdates",
  ]
  assert_eq(expected_lasting.length(), 14)
  for name in expected_lasting {
    assert_false(topic_policy_sensitive(name, empty))
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

  let expected_sensitive : Array[String] = [
    "accounts", "lock", "lockDraft", "lockPrompts", "loginSessions", "machineLogins", "machineLogin",
    "machineLoginScreen", "slackTokens", "admin", "adminList", "adminItem", "adminOverview", "adminRelays",
    "vaults", "vaultItems", "vaultUses", "rigs", "devices", "memberships", "joinable",
  ]
  assert_eq(expected_sensitive.length(), 21)
  for name in expected_sensitive {
    assert_true(topic_policy_sensitive(name, empty))
    for policy in [true, false] {
      assert_false(topic_policy_lasting_by(name, empty, policy))
      assert_eq(topic_policy_keep_by(name, empty, true, policy), 0)
      assert_eq(topic_policy_keep_by(name, empty, false, policy), 0)
      assert_false(topic_policy_show_kept_by(name, empty, true, policy))
      assert_false(topic_policy_show_kept_by(name, empty, false, policy))
    }
  }

  // stationPart byParam branches
  for part in ["machineLogins", "logins"] {
    let p = Json::object({ "scope": Json::string("w1"), "station": Json::string("w1/s1"), "part": Json::string(part) })
    assert_true(topic_policy_sensitive("stationPart", p))
    for policy in [true, false] {
      assert_eq(topic_policy_keep_by("stationPart", p, true, policy), 0)
      assert_false(topic_policy_show_kept_by("stationPart", p, true, policy))
    }
  }
  for part in ["archiving", "automaticDecisions", "unknownPart"] {
    let p = Json::object({ "scope": Json::string("w1"), "station": Json::string("w1/s1"), "part": Json::string(part) })
    assert_false(topic_policy_sensitive("stationPart", p))
    assert_eq(topic_kept_by("stationPart", p, true), 0)
    assert_false(topic_policy_show_kept("stationPart", p, true))
  }
  assert_eq(topic_kept_by("stationPart", empty, true), 0)
  assert_false(topic_policy_show_kept("stationPart", empty, true))
  for part in ["profiles", "updates", "copies"] {
    let p = Json::object({ "scope": Json::string("w1"), "station": Json::string("w1/s1"), "part": Json::string(part) })
    assert_false(topic_policy_sensitive("stationPart", p))
    assert_eq(topic_kept_by("stationPart", p, true), 24)
    assert_eq(topic_kept_by("stationPart", p, false), 0)
    assert_true(topic_policy_show_kept("stationPart", p, true))
    assert_false(topic_policy_show_kept("stationPart", p, false))
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
    ("profile", 16),
    ("profilesOverview", 4),
    ("presets", 8),
    ("otherPresets", 8),
    ("releases", 4),
    ("fonts", 4),
    ("connect", 16),
    ("connectCandidates", 8),
    ("pick", 12),
    ("drivePlace", 24),
    ("chatOutline", 8),
    ("projects", 8),
    ("project", 16),
    ("tags", 8),
  ]
  assert_eq(expected_views.length(), 20)
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

  // PR-B2b delta topics (showKept = false, keep = 8 when policy=true, 0 when policy=false)
  for name in ["jobLog", "chatFeedback"] {
    assert_false(topic_policy_lasting_by(name, empty, true))
    assert_false(topic_policy_show_kept_by(name, empty, true, true))
    assert_eq(topic_policy_keep_by(name, empty, true, true), 8)
    assert_eq(topic_policy_keep_by(name, empty, false, true), 8)
    assert_eq(topic_policy_keep_by(name, empty, true, false), 0)
    assert_eq(topic_policy_keep_by(name, empty, false, false), 0)
  }

  // PR-B2b MBUI_TOPIC_POLICY switch off downgrades all 8 upgraded topics to live (0 / false)
  assert_true(topic_policy_lasting_by("workspaces", empty, true))
  assert_false(topic_policy_lasting_by("workspaces", empty, false))
  assert_eq(topic_policy_keep_by("workspaces", empty, true, true), 64)
  assert_eq(topic_policy_keep_by("workspaces", empty, true, false), 0)
  for name in ["profilesOverview", "presets", "otherPresets", "releases", "fonts"] {
    assert_true(topic_policy_show_kept_by(name, empty, true, true))
    assert_false(topic_policy_show_kept_by(name, empty, true, false))
    assert_eq(topic_policy_keep_by(name, empty, true, false), 0)
  }

  assert_eq(kept_most_by(true), 96)
  assert_eq(kept_most_by(false), 64)

  for name in ["accounts", "chatSearch", "search", "stationSearch", "chatSubchats", "notify"] {
    assert_false(topic_policy_lasting(name, empty))
    assert_eq(topic_kept_by(name, empty, true), 0)
    assert_false(topic_shown_kept(name))
  }
}

///|
test "drivePlace kept state (version -2/-3) displays retained place and keep_place saves progress without extra topic read" {
  let place_ver : Ref[Int] = Ref(-2)
  let place_val : Ref[Json?] = Ref(Some({ "at": 42.0, "of": 100.0 }))
  let topic_reads : Ref[Int] = Ref(0)
  let calls : Array[(String, Json)] = []
  let base = made_source(call=fn(name, params, done) {
    calls.push((name, params))
    done(Ok(Json::null()))
  })
  let src : Source = {
    ..base,
    topic_read: fn(name, _params) {
      if name == "drivePlace" {
        topic_reads.val += 1
        { value: place_val.val, error: None, version: place_ver.val }
      } else {
        { value: None, error: None, version: 0 }
      }
    },
  }
  let at : DriveAt = { station: "w1/s1", root: Some("home"), path: "book.txt" }
  let vf = drive_viewer_file(src, at)

  // While drivePlace is retained (version = -2, Client::show_kept), read-only place() renders the retained position.
  match (vf.place)() {
    LeftAt(at_pos, of_pos) => {
      assert_eq(at_pos, 42.0)
      assert_eq(of_pos, 100.0)
    }
    _ => fail("expected LeftAt(42.0, 100.0) while retained")
  }
  let reads_before_keep = topic_reads.val

  // Writing drive.place on exit must NOT trigger an extra drivePlace subscription and must NOT drop progress.
  (vf.keep_place)(55.0, 100.0)
  assert_eq(topic_reads.val, reads_before_keep)
  assert_eq(calls.length(), 1)
  assert_eq(calls[0].0, "drive.place")
  assert_eq(number(Some(calls[0].1), "at"), 55.0)
  assert_eq(number(Some(calls[0].1), "of"), 100.0)

  // LastSaid version (-3) also preserves progress write-back without extra reads.
  place_ver.val = -3
  (vf.keep_place)(60.0, 100.0)
  assert_eq(topic_reads.val, reads_before_keep)
  assert_eq(calls.length(), 2)
  assert_eq(number(Some(calls[1].1), "at"), 60.0)
}

///|
test "topic_kept and topic_shown_kept_params follow topic_policy_enabled while sensitive ceiling stays unconditional" {
  let prev = topic_policy_enabled.val
  defer { topic_policy_enabled.val = prev }
  let empty = Json::object({})
  topic_policy_enabled.val = fn() { false }
  assert_eq(topic_kept("workspaces", empty), 0)
  assert_eq(topic_kept("jobLog", empty), 0)
  assert_false(topic_shown_kept_params("otherPresets", empty))
  assert_eq(topic_kept("vaults", empty), 0)
  assert_false(topic_shown_kept_params("vaults", empty))

  topic_policy_enabled.val = fn() { true }
  assert_eq(topic_kept("workspaces", empty), 64)
  assert_eq(topic_kept("jobLog", empty), 8)
  assert_true(topic_shown_kept_params("otherPresets", empty))
  assert_eq(topic_kept("vaults", empty), 0)
  assert_false(topic_shown_kept_params("vaults", empty))
}

///|
test "TopicState::is_retained distinguishes unconfirmed (<0) from fresh (>=0) for press_wait gating" {
  let retained_show : TopicState = { value: Some({ "terminals": [] }), error: None, version: -2, waiting: false }
  let retained_last : TopicState = { value: Some({ "terminals": [] }), error: None, version: -3, waiting: false }
  let fresh : TopicState = { value: Some({ "terminals": [] }), error: None, version: 0, waiting: false }
  assert_true(opens_answered(retained_show) && retained_show.is_retained())
  assert_true(opens_answered(retained_last) && retained_last.is_retained())
  assert_false(opens_answered(retained_show) && !retained_show.is_retained())
  assert_true(opens_answered(fresh) && !fresh.is_retained())
}
