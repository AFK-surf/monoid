// `in_use_places` and `jobs_up_places` give of each row what `sessions_in_use` and `jobs_up` give of it, read the way
// cold storage reads those (session_storage cold.mbt: a string, else its fallback), without making the row whole.

///|
fn as_text(v : Json?) -> String? {
  match v {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
test "a session's places as sessions_in_use gives them" {
  let rows : Array[Map[String, Json]] = [
    { "key": "a", "workspace": "/s/a/workspace", "cwd": "/s/a/workspace/repo", "running": 0 },
    { "key": "b", "workspace": "/s/b/workspace", "cwd": Json::null(), "running": 1 },
    { "key": "c", "workspace": Json::null(), "cwd": Json::null(), "running": 0 },
    { "key": "d", "workspace": Json::null(), "cwd": "/elsewhere", "running": 0 },
    { "key": "e", "workspace": 3, "cwd": 4, "running": 0 },
  ]
  for r in rows {
    let s = to_session(r)
    let ws = as_text(field(s, "workspace")).unwrap_or("")
    let whole = (as_text(field(s, "key")).unwrap_or(""), ws, as_text(field(s, "cwd")).unwrap_or(ws))
    assert_eq(place_of_session(r), whole)
  }
  assert_eq(rows.map(place_of_session), [
    ("a", "/s/a/workspace", "/s/a/workspace/repo"),
    ("b", "/s/b/workspace", "/s/b/workspace"),
    ("c", "", ""),
    ("d", "", "/elsewhere"),
    ("e", "", ""),
  ])
}

///|
test "a job's place as jobs_up gives it" {
  let rows : Array[Map[String, Json]] = [
    { "id": "j1", "session_key": "a", "cwd": "/s/a/workspace", "state": "running" },
    { "id": "j2", "session_key": Json::null(), "cwd": Json::null(), "state": "exited", "port": 3000 },
  ]
  for r in rows {
    let j = to_job(r)
    assert_eq(place_of_job(r), (as_text(field(j, "sessionKey")).unwrap_or(""), as_text(field(j, "cwd")).unwrap_or("")))
  }
  assert_eq(rows.map(place_of_job), [("a", "/s/a/workspace"), ("", "")])
}

///|
test "the places' statements ask what sessions_in_use and jobs_up ask, fewer columns" {
  // the sessions shown or running (live_sessions, running_sessions), the jobs up (jobs_up), each on its index
  assert_true(in_use_places.contains("WHERE archived_at IS NULL UNION"))
  assert_true(in_use_places.contains("WHERE running = 1"))
  assert_true(live_sessions.contains("WHERE archived_at IS NULL"))
  assert_true(running_sessions.contains("WHERE running = 1"))
  assert_true(jobs_up_places.contains("WHERE state = 'running' UNION ALL"))
  assert_true(jobs_up_places.contains("WHERE state = 'exited' AND port IS NOT NULL"))
  assert_true(jobs_up.contains("WHERE state = 'running' UNION ALL SELECT * FROM jobs WHERE state = 'exited' AND port IS NOT NULL"))
}
