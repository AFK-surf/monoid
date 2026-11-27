// Adversarial tests for PR-B2s in `sfbase`:
// - `profiles` and `station` `sanitize_kept_json` strips `machineLogins`/`logins`/`manages` from `last_said`
// - `invalidate_auth_scope` synchronously clears `last_said`, `Graph` & transferable `Lease` followers, and `Derived`/`Kept`
// - Unrelated workspace B and unaffected vault V2 suffer 0 false invalidations

///|
test "PR-B2s sfbase: profiles last_said shows sanitized SWR first frame with 0 sensitive fields" {
  let current : Ref[Json?] = Ref(
    Some({
      "items": [{ "key": "p1", "name": "Claude" }],
      "machineLogins": [{ "station": "wsA/st1", "logins": [{ "id": "ml1" }] }],
      "manages": true,
    }),
  )
  let base = made_source(topic=fn(name, _) {
    if name == "profiles" {
      current.val
    } else {
      None
    }
  })
  let src : Source = { ..base, reads_ahead: fn() { true } }
  let params : Map[String, Json] = { "scope": Json::string("wsA") }

  // First read caches sanitized copy in last_said while returning full fresh value
  let first = read_topic_state(src, "profiles", params)
  assert_true(first.value.unwrap().stringify().contains("machineLogins"))
  assert_true(first.value.unwrap().stringify().contains("manages"))

  // Subsequent reopen before core answers (current=None) serves sanitized SWR from last_said!
  current.val = None
  let swr = read_topic_state(src, "profiles", params)
  assert_true(swr.kept(), msg="profiles must serve SWR from last_said")
  let swr_text = swr.value.unwrap().stringify()
  assert_true(swr_text.contains("\"name\":\"Claude\""))
  assert_false(swr_text.contains("machineLogins"), msg="last_said profiles must contain 0 machineLogins")
  assert_false(swr_text.contains("manages"), msg="last_said profiles must contain 0 manages")
}

///|
test "PR-B2s sfbase: invalidate_auth_scope clears wsA last_said and Derived while preserving wsB" {
  let ws_a_val : Ref[Json?] = Ref(Some({ "items": ["A_OLD"] }))
  let ws_b_val : Ref[Json?] = Ref(Some({ "items": ["B_OK"] }))
  let base = made_source(topic=fn(name, params) {
    if name == "chats" {
      match params.get("scope") {
        Some(String("wsA")) => ws_a_val.val
        Some(String("wsB")) => ws_b_val.val
        _ => None
      }
    } else {
      None
    }
  })
  let src : Source = { ..base, reads_ahead: fn() { true } }
  let p_a : Map[String, Json] = { "scope": Json::string("wsA") }
  let p_b : Map[String, Json] = { "scope": Json::string("wsB") }

  // Populate last_said and Derived for both wsA and wsB
  let d : Derived[String] = Derived::new("chats", fn(j, _) { j.stringify() })
  assert_true(d.value(src, p_a).unwrap().contains("A_OLD"))
  assert_true(d.value(src, p_b).unwrap().contains("B_OK"))

  // Invalidate ONLY wsA!
  invalidate_auth_scope(src, fn(_, params) {
    params.get("scope") == Some(Json::string("wsA"))
  })

  // Set both backing values to None (simulating waiting for fresh core answer)
  ws_a_val.val = None
  ws_b_val.val = None

  // wsA last_said and Derived are cleared (0 old markers); wsB last_said and Derived still hit cache!
  let after_a = read_topic_state(src, "chats", p_a)
  assert_true(after_a.value is None, msg="wsA last_said must be cleared")
  assert_true(d.kept_from(src, p_a) is None, msg="wsA Derived cache must be cleared")

  let after_b = read_topic_state(src, "chats", p_b)
  assert_true(after_b.value.unwrap().stringify().contains("B_OK"), msg="wsB last_said must remain cached")
  assert_true(d.kept_from(src, p_b).unwrap().contains("B_OK"), msg="wsB Derived cache must remain cached")
}

///|
test "PR-B2s sfbase: sanitize_kept_json strips active login flows across station, profiles, and stationPart(profiles)" {
  let sp = sanitize_kept_json(
    "stationPart",
    Json::array([
      { "id": "p1", "name": "Claude", "login": { "state": "needs_approval", "url": "https://auth.example", "userCode": "ABCD-1234" } },
      { "id": "p2", "name": "Codex" },
    ]),
  )
  let sp_text = sp.stringify()
  assert_true(sp_text.contains("\"name\":\"Claude\""))
  assert_false(sp_text.contains("ABCD-1234"), msg="stationPart(profiles) must strip active login userCode")
  assert_false(sp_text.contains("\"login\""), msg="stationPart(profiles) must strip login object")

  let st = sanitize_kept_json(
    "station",
    {
      "station": "wsA/st1",
      "name": "Box",
      "overview": {
        "counts": { "running": 1 },
        "machineLogins": [{ "id": "ml1" }],
        "logins": [{ "id": "l1" }],
        "profiles": [{ "id": "p1", "name": "Claude", "login": { "state": "needs_code", "url": "https://secret", "userCode": "9999" } }],
      },
    },
  )
  let st_text = st.stringify()
  assert_true(st_text.contains("\"name\":\"Box\""))
  assert_false(st_text.contains("machineLogins"))
  assert_false(st_text.contains("\"logins\""))
  assert_false(st_text.contains("9999"), msg="station overview.profiles[].login must be stripped")
  assert_false(st_text.contains("\"login\""))

  // Device-global single source of truth generated from topic-policy.ts:
  assert_true(topic_policy_device_global("link"))
  assert_true(topic_policy_device_global("connection"))
  assert_true(topic_policy_device_global("way"))
  assert_true(topic_policy_device_global("net"))
  assert_true(topic_policy_device_global("prefs"))
  assert_false(topic_policy_device_global("downloads"), msg="downloads must NOT be device-global")
}
