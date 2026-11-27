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

///|
test "PR-B2s sfbase: invalidate_auth_scope keeps watched topics and Derived reactive while clearing last_said and kept_from" {
  let accounts_sig : @signals.Signal[Json?] = @signals.signal(None)
  let chats_sig : @signals.Signal[Json?] = @signals.signal(Some({ "items": ["A_OLD"] }))
  let base = made_source(topic=fn(name, params) {
    if name == "accounts" {
      accounts_sig.get()
    } else if name == "chats" && params.get("scope") == Some(Json::string("wsA")) {
      chats_sig.get()
    } else {
      None
    }
  })
  let src : Source = { ..base, reads_ahead: fn() { true } }
  let p_a : Map[String, Json] = { "scope": Json::string("wsA") }

  // 1) Cold-start handshake: live reactive watcher on `accounts` starts at None,
  // Global auth boundary fires, then `accounts` arrives -> watcher must wake up!
  let seen_accounts : Ref[Json?] = Ref(None)
  let stop_acc = @signals.effect(fn() {
    seen_accounts.val = src.topic("accounts", {}).get().value
  })
  assert_true(seen_accounts.val is None)
  invalidate_auth_scope(src, fn(name, _) { !topic_policy_device_global(name) })
  accounts_sig.set(Some(Json::array([])))
  assert_true(seen_accounts.val is Some(Array(_)), msg="watched accounts topic must remain reactive after auth boundary")
  stop_acc()

  // 2) Live watched Derived + last_said SWR: auth boundary must drop SWR immediately
  // and clear kept_from, while keeping the watched Derived reactive for fresh data.
  let d : Derived[String] = Derived::new("chats", fn(j, _) { j.stringify() })
  let seen_chats : Ref[String?] = Ref(None)
  let stop_chats = @signals.effect(fn() {
    seen_chats.val = d.value(src, p_a)
  })
  assert_true(seen_chats.val.unwrap().contains("A_OLD"))
  // Underlying topic goes None -> SWR from last_said still serves A_OLD until boundary
  chats_sig.set(None)
  assert_true(seen_chats.val.unwrap().contains("A_OLD"))
  invalidate_auth_scope(src, fn(_, params) { params.get("scope") == Some(Json::string("wsA")) })
  assert_true(d.kept_from(src, p_a) is None, msg="wsA Derived kept_from must be cleared on auth boundary")
  assert_true(seen_chats.val is None, msg="watched Derived must drop last_said SWR immediately on auth boundary")
  chats_sig.set(Some({ "items": ["A_NEW"] }))
  assert_true(seen_chats.val.unwrap().contains("A_NEW"), msg="watched Derived must stay reactive and receive fresh post-boundary data")
  stop_chats()
}

///|
test "Direction 2A sfbase: watched FollowedTopic, Derived, and Kept survive repeated Global/Workspace/Vault invalidations with 0 broken links and 0 stale leakage" {
  let acc_sig : @signals.Signal[Json?] = @signals.signal(Some(Json::array([{ "sub": "u1" }])))
  let chats_a_sig : @signals.Signal[Json?] = @signals.signal(Some({ "items": ["A1"] }))
  let chats_b_sig : @signals.Signal[Json?] = @signals.signal(Some({ "items": ["B1"] }))
  let vault_v1_sig : @signals.Signal[Json?] = @signals.signal(Some({ "items": ["V1_SECRET"] }))
  let vault_v2_sig : @signals.Signal[Json?] = @signals.signal(Some({ "items": ["V2_OK"] }))

  let base = made_source(topic=fn(name, params) {
    match name {
      "accounts" => acc_sig.get()
      "chats" =>
        match params.get("scope") {
          Some(String("wsA")) => chats_a_sig.get()
          Some(String("wsB")) => chats_b_sig.get()
          _ => None
        }
      "vaultItems" =>
        match (params.get("workspace"), params.get("vault")) {
          (Some(String("wsA")), Some(String("v1"))) => vault_v1_sig.get()
          (Some(String("wsA")), Some(String("v2"))) => vault_v2_sig.get()
          _ => None
        }
      _ => None
    }
  })
  let src : Source = { ..base, reads_ahead: fn() { true } }
  let p_a : Map[String, Json] = { "scope": Json::string("wsA") }
  let p_b : Map[String, Json] = { "scope": Json::string("wsB") }
  let p_v1 : Map[String, Json] = { "workspace": Json::string("wsA"), "vault": Json::string("v1") }
  let p_v2 : Map[String, Json] = { "workspace": Json::string("wsA"), "vault": Json::string("v2") }

  // Derived that tracks whether `was` was ever leaked across a boundary!
  let leaked_was : Ref[Int] = Ref(0)
  let d_chats_runs : Ref[Int] = Ref(0)
  let d_chats : Derived[String] = Derived::new("chats", fn(j, was) {
    d_chats_runs.val += 1
    if was is Some(prev) && prev.contains("A1") && j.stringify().contains("A2") {
      leaked_was.val += 1
    }
    j.stringify()
  })
  let d_v1 : Derived[String] = Derived::new("vaultItems", fn(j, _) { j.stringify() })
  let d_v2 : Derived[String] = Derived::new("vaultItems", fn(j, _) { j.stringify() })

  // Standalone Kept keyed by topic_key to verify `SourceKept` drops `was` across boundaries too.
  let tracking_inval : Ref[Bool] = Ref(false)
  let kept_runs_on_inval : Ref[Int] = Ref(0)
  let kept_saw_prev_after_inval : Ref[Bool] = Ref(false)
  let k_v1 : Kept[String] = Kept::new()
  let k_v1_key = topic_key("vaultItems", p_v1)

  let seen_acc : Ref[Json?] = Ref(None)
  let seen_a : Ref[String?] = Ref(None)
  let seen_b : Ref[String?] = Ref(None)
  let seen_v1 : Ref[String?] = Ref(None)
  let seen_v2 : Ref[String?] = Ref(None)
  let seen_kept_v1 : Ref[String] = Ref("")

  let stop_acc = @signals.effect(fn() { seen_acc.val = src.topic("accounts", {}).get().value })
  let stop_a = @signals.effect(fn() { seen_a.val = d_chats.value(src, p_a) })
  let stop_b = @signals.effect(fn() { seen_b.val = d_chats.value(src, p_b) })
  let stop_v1 = @signals.effect(fn() { seen_v1.val = d_v1.value(src, p_v1) })
  let stop_v2 = @signals.effect(fn() { seen_v2.val = d_v2.value(src, p_v2) })
  let stop_k = @signals.effect(fn() {
    seen_kept_v1.val = k_v1.read(src, k_v1_key, fn(was) {
      if tracking_inval.val {
        kept_runs_on_inval.val += 1
        if was is Some(_) {
          kept_saw_prev_after_inval.val = true
        }
      }
      match src.topic("vaultItems", p_v1).get().value {
        Some(v) => v.stringify()
        None => "EMPTY"
      }
    })
  })

  // Also populate an unwatched Derived on wsA to confirm unwatched entries ARE disposed & evicted.
  let d_unwatched : Derived[String] = Derived::new("chats", fn(j, _) { "U:" + j.stringify() })
  assert_true(d_unwatched.value(src, p_a).unwrap().contains("A1"))

  // Boundary 1: Vault(wsA, v1) invalidation while all readers are watched
  vault_v1_sig.set(None)
  tracking_inval.val = true
  invalidate_auth_scope(src, fn(name, params) {
    name == "vaultItems" && params.get("workspace") == Some(Json::string("wsA")) && params.get("vault") == Some(Json::string("v1"))
  })
  tracking_inval.val = false
  assert_true(seen_v1.val is None, msg="v1 watched Derived must drop immediately on Vault boundary")
  assert_eq(seen_kept_v1.val, "EMPTY", msg="v1 watched Kept must recompute on Vault boundary")
  assert_true(kept_runs_on_inval.val > 0, msg="watched Kept must re-evaluate on Vault boundary")
  assert_false(kept_saw_prev_after_inval.val, msg="watched Kept must not receive stale `was` after boundary")
  assert_true(seen_v2.val.unwrap().contains("V2_OK"), msg="v2 must be untouched by v1 boundary")
  assert_true(seen_b.val.unwrap().contains("B1"), msg="wsB must be untouched by v1 boundary")

  // Boundary 2: Workspace(wsA) invalidation — in a single batch, transition directly A1 -> A2
  // (never passing through None) while invalidating wsA, and verify d_chats ran with `was == None`.
  let runs_before_ws_inval = d_chats_runs.val
  @signals.start_batch()
  chats_a_sig.set(Some({ "items": ["A2"] }))
  invalidate_auth_scope(src, fn(_, params) {
    params.get("scope") == Some(Json::string("wsA")) || params.get("workspace") == Some(Json::string("wsA"))
  })
  @signals.end_batch()
  assert_true(d_chats_runs.val > runs_before_ws_inval, msg="d_chats must recompute on batched Workspace boundary A1 -> A2")
  assert_true(seen_a.val.unwrap().contains("A2"), msg="wsA watched Derived must see A2 directly")
  assert_eq(leaked_was.val, 0, msg="batched direct A1 -> A2 across Workspace boundary must pass was=None")
  assert_true(d_unwatched.kept_from(src, p_a) is None, msg="unwatched Derived must be evicted on Workspace boundary")
  assert_true(seen_b.val.unwrap().contains("B1"), msg="wsB must remain intact on wsA boundary")

  // Boundary 3: Global invalidation (repeated back-to-back)
  acc_sig.set(None)
  chats_a_sig.set(None)
  invalidate_auth_scope(src, fn(name, _) { !topic_policy_device_global(name) })
  invalidate_auth_scope(src, fn(name, _) { !topic_policy_device_global(name) })
  assert_true(seen_acc.val is None)
  assert_true(seen_a.val is None, msg="wsA watched Derived must drop SWR on Global boundary")
  assert_true(d_chats.kept_from(src, p_a) is None, msg="wsA kept_from must be None after Global boundary")

  // Post-boundary fresh data arrives: ALL watched readers must still be live and receive updates!
  acc_sig.set(Some(Json::array([{ "sub": "u2" }])))
  chats_a_sig.set(Some({ "items": ["A2"] }))
  chats_b_sig.set(Some({ "items": ["B2"] }))
  vault_v1_sig.set(Some({ "items": ["V1_FRESH"] }))
  vault_v2_sig.set(Some({ "items": ["V2_FRESH"] }))

  assert_true(seen_acc.val.unwrap().stringify().contains("u2"), msg="accounts watcher must remain live after repeated boundaries")
  assert_true(seen_a.val.unwrap().contains("A2"), msg="wsA chats Derived must remain live after repeated boundaries")
  assert_true(seen_b.val.unwrap().contains("B2"), msg="wsB chats Derived must remain live after repeated boundaries")
  assert_true(seen_v1.val.unwrap().contains("V1_FRESH"), msg="v1 Derived must remain live after repeated boundaries")
  assert_true(seen_v2.val.unwrap().contains("V2_FRESH"), msg="v2 Derived must remain live after repeated boundaries")
  assert_true(seen_kept_v1.val.contains("V1_FRESH"), msg="v1 Kept must remain live after repeated boundaries")
  assert_eq(leaked_was.val, 0, msg="Derived must never pass pre-boundary `was` into post-boundary recomputation")

  stop_acc()
  stop_a()
  stop_b()
  stop_v1()
  stop_v2()
  stop_k()
}

///|
test "Direction 2A sfbase: let_go_unread and invalidate_auth_scope outside frame/batch release exactly once / zero times" {
  let releases : Array[String] = []
  let base = made_source(topic=fn(name, _) {
    if name == "longJobs" || name == "chats" {
      Some({ "items": [] })
    } else {
      None
    }
  })
  let src : Source = {
    ..base,
    release: fn(name, _) { releases.push(name) },
  }
  let p : Map[String, Json] = { "scope": Json::string("wsR") }

  // 1) Declared unread topic released via `declared_let_go` outside any frame/batch: must release EXACTLY once!
  declare_topic(src, "longJobs", p) |> ignore
  declared_let_go()
  assert_eq(releases.length(), 1, msg="declared_let_go must call src.release exactly once (no re-entrant double release)")
  assert_eq(releases[0], "longJobs")

  // 2) `invalidate_auth_scope` on both unwatched (declared) and watched topics outside frame/batch: 0 spurious releases
  declare_topic(src, "chats", p) |> ignore
  releases.clear()
  invalidate_auth_scope(src, fn(name, _) { name == "chats" })
  assert_eq(releases.length(), 0, msg="invalidate_auth_scope on unwatched topic must not trigger spurious release")
  declared_let_go()
  assert_eq(releases.length(), 0, msg="declared_let_go after invalidate_auth_scope must not double-release")

  let stop = @signals.effect(fn() { src.topic("chats", p).get() |> ignore })
  invalidate_auth_scope(src, fn(name, _) { name == "chats" })
  assert_eq(releases.length(), 0, msg="invalidate_auth_scope on watched topic must not trigger release")
  stop()
}
