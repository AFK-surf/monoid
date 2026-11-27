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
    "workspace", "stations", "stationNet", "screens", "terminals", "profiles", "connects", "usage",
    "archive", "chats", "longJobs", "changelog", "stationUpdates",
  ]
  assert_eq(expected_lasting.length(), 13)
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

  // workspaces remains LIVE regardless of MBUI_TOPIC_POLICY
  assert_false(topic_policy_lasting_by("workspaces", empty, true))
  assert_false(topic_policy_lasting_by("workspaces", empty, false))
  assert_eq(topic_policy_keep_by("workspaces", empty, true, true), 0)
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
  assert_eq(topic_kept("workspaces", empty), 0)
  assert_eq(topic_kept("jobLog", empty), 8)
  assert_true(topic_shown_kept_params("otherPresets", empty))
  assert_eq(topic_kept("vaults", empty), 0)
  assert_false(topic_shown_kept_params("vaults", empty))
}

///|
test "TopicState::is_retained, is_confirmed, and is_confirmed_known distinguish retained, empty, unknown, outdated, and confirmed" {
  let retained_show : TopicState = { value: Some({ "terminals": [], "known": true, "confirmed": true }), error: None, version: -2, waiting: false }
  let retained_last : TopicState = { value: Some({ "terminals": [], "known": true, "confirmed": true }), error: None, version: -3, waiting: false }
  let empty_unconfirmed : TopicState = { value: None, error: None, version: 0, waiting: false }
  let unknown_open : TopicState = { value: Some({ "terminals": [], "known": false, "confirmed": false, "open": true }), error: None, version: 0, waiting: false }
  let unconfirmed_known : TopicState = { value: Some({ "terminals": [], "known": true, "confirmed": false, "open": true }), error: None, version: 1, waiting: false }
  let outdated_known : TopicState = { value: Some({ "terminals": [], "known": true, "confirmed": true, "outdated": true, "open": true }), error: None, version: 1, waiting: false }
  let fresh : TopicState = { value: Some({ "terminals": [], "known": true, "confirmed": true, "outdated": false }), error: None, version: 0, waiting: false }
  assert_true(opens_answered(retained_show) && retained_show.is_retained())
  assert_true(opens_answered(retained_last) && retained_last.is_retained())
  assert_false(opens_answered(retained_show) && !retained_show.is_retained())
  assert_false(retained_show.is_confirmed())
  assert_false(retained_last.is_confirmed())
  assert_false(empty_unconfirmed.is_retained())
  assert_false(empty_unconfirmed.is_confirmed())
  assert_true(unknown_open.is_confirmed())
  assert_false(unknown_open.is_confirmed_known())
  assert_true(unconfirmed_known.is_confirmed())
  assert_false(unconfirmed_known.is_confirmed_known())
  assert_true(outdated_known.is_confirmed())
  assert_false(outdated_known.is_confirmed_known())
  assert_true(opens_answered(fresh) && !fresh.is_retained() && fresh.is_confirmed() && fresh.is_confirmed_known())
}

///|
test "chat_remote_open press_wait waits while terminals is retained (-2) and opens menu once fresh (>=0) arrives" {
  let prev_cap = terminals_capable_fn.val
  terminals_capable_fn.val = fn() { true }
  defer {
    terminals_capable_fn.val = prev_cap
    @sf.presenters_reset()
  }
  let t = @ui.Tester::new(fn(_) {  }, tree=fn(_) {  })
  let tree = @ui.view_tree().unwrap()
  let terms_ver : @signals.Signal[Int] = @signals.signal(-2)
  let terms_val : Json = {
    "known": true,
    "confirmed": true,
    "outdated": false,
    "open": true,
    "terminals": [{ "id": "t-1", "cwd": "/work/proj", "ended": false, "chat": "c-1" }],
  }
  let base = made_source()
  let src : Source = {
    ..base,
    asks_terminals: fn() { true },
    topic_read: fn(name, _params) {
      if name == "terminals" {
        { value: Some(terms_val), error: None, version: terms_ver.get() }
      } else if name == "screens" {
        { value: Some({ "known": true, "confirmed": true, "outdated": false, "screens": [] }), error: None, version: 1 }
      } else {
        { value: None, error: None, version: 0 }
      }
    },
  }
  let r : ChatRef = { station: "w1/s1", session: "c-1", title: "Chat", station_name: "Studio" }
  let v = chat_view_made({ "key": "c-1", "canTerminal": true, "canBrowser": false, "screens": [] })
  chat_remote_caps[v.key] = (false, true)
  defer { chat_remote_caps.remove(v.key) }
  let before = @sf.last_presented()
  tree.event(t.time(), fn() {
    chat_remote_open(src, r, v, from=@sf.at_point(20.0, 20.0))
  })
  t.draw()
  // While retained (-2), press_wait must NOT open the menu yet.
  assert_eq(@sf.last_presented(), before)

  // Once fresh (version = 1) arrives, press_wait opens the menu immediately.
  tree.event(t.time() + 10.0, fn() { terms_ver.set(1) })
  t.draw()
  assert_true(@sf.last_presented() > before)
}

///|
test "chat_remote_open timeout menu keeps live terminals guard and recovers when fresh arrives" {
  let prev_cap = terminals_capable_fn.val
  terminals_capable_fn.val = fn() { true }
  defer {
    terminals_capable_fn.val = prev_cap
    @sf.presenters_reset()
  }
  let t = @ui.Tester::new(fn(_) {  }, tree=fn(_) {  })
  let tree = @ui.view_tree().unwrap()
  let terms_ver : @signals.Signal[Int] = @signals.signal(-2)
  let terms_open : @signals.Signal[Bool] = @signals.signal(true)
  let base = made_source()
  let src : Source = {
    ..base,
    asks_terminals: fn() { true },
    topic_read: fn(name, _params) {
      if name == "terminals" {
        {
          value: Some({ "known": true, "confirmed": true, "outdated": false, "open": terms_open.get(), "terminals": [] }),
          error: None,
          version: terms_ver.get(),
        }
      } else {
        { value: None, error: None, version: 0 }
      }
    },
  }
  let r : ChatRef = { station: "w1/s1", session: "c-1", title: "Chat", station_name: "Studio" }
  let v = chat_view_made({ "key": "c-2", "canTerminal": true, "canBrowser": false, "screens": [] })
  chat_remote_caps[v.key] = (false, true)
  defer { chat_remote_caps.remove(v.key) }
  let before = @sf.last_presented()
  tree.event(t.time(), fn() {
    chat_remote_open(src, r, v, from=@sf.at_point(20.0, 20.0))
  })
  t.draw()
  assert_eq(@sf.last_presented(), before)

  // Advance past press_wait deadline: menu opens after timeout while terminals is still retained (-2).
  t.run_for(@sf.open_hold_ms + 50.0)
  assert_true(@sf.last_presented() > before)

  // Fresh arrival (version = 1) with open: true makes live sub confirmed+known and capable while menu is still open.
  tree.event(t.time() + 10.0, fn() { terms_ver.set(1) })
  t.draw()
  let live_st = src.topic("terminals", { "station": Json::string("w1/s1") }).get()
  assert_true(live_st.is_confirmed_known() && flag(live_st.value, "open"))
}
