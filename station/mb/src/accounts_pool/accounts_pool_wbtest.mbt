// Native whitebox tests for accounts_pool: model keys, ISO time parsing, percentages/labels/slugs/masks,
// allowance urgency, decision model filtering, pool selection, and cooldown calculations.

///|
test "a model's key, however it is spelled" {
  assert_eq(model_key("anthropic/claude-opus-5-5-20251101[1m]"), "claude-opus-5-5[1m]")
  assert_eq(model_key("us.anthropic.claude-sonnet-5-5-v1:0"), "claude-sonnet-5-5")
  assert_eq(model_key("fusion-claude-opus-5-5-high-sidekick-swe-2-medium"), "fusion-claude-opus-5-5-sidekick-swe-2-medium")
}

///|
test "ISO times as V8 reads them" {
  let utc = (_ : Double) => 0.0
  assert_eq(date_parse("2026-11-16T11:59:59.936566+00:00", utc), Some(1794830399936.0))
  assert_eq(date_parse("2026-02-30T00:00:00Z", utc), Some(1772409600000.0))
  assert_eq(date_parse("2026-11-16T24:00:00Z", utc), Some(1794873600000.0))
  assert_eq(date_parse("2026-11-16T11:59:60Z", utc), None)
  assert_eq(date_parse("2026-11-16T11:59:59+0000", utc), Some(1794830399000.0))
  assert_eq(date_parse("2026-11-16T11:59Z", utc), Some(1794830340000.0))
  assert_eq(date_parse("2026-11-16T11:59:59Zjunk", utc), None)
}

///|
test "percentages, labels, slugs, masks" {
  assert_eq(percent(Some(Num(99.5))), 100.0)
  assert_eq(percent(Some(Str(" 7 "))), 7.0)
  assert_eq(window_label(Some(300.0), "x"), "5 小时")
  assert_eq(window_label(Some(10080.0), "x"), "每周")
  assert_eq(window_label(Some(2880.0), "x"), "2 天")
  assert_eq(slug("Me@Example.com", 40), "me-example-com")
  assert_eq(mask("sk-abcdefghijklmnop"), "sk-ab…mnop")
  assert_eq(mask("short"), "••••")
}

///|
test "the pool's urgency of an allowance" {
  let now = 1_800_000_000_000.0
  let q = jobj([
    ("state", js("ok")),
    (
      "windows",
      jarr([
        jobj([("usedPercent", jnum(90.0)), ("minutes", jnum(300.0)), ("resetsAt", jnum(now + 3_600_000.0))]),
        jobj([("usedPercent", jnum(20.0)), ("minutes", jnum(10080.0)), ("resetsAt", jnum(now + 5.0 * 86_400_000.0))]),
      ]),
    ),
  ])
  let u = urgency(Some(q), now)
  assert_true(u.crowded)
  assert_true(u.weight > 0.0)
}

///|
fn[X] accounts_ran(f : async () -> X) -> X {
  let rt = @effect.Runtime::new()
  let fiber = rt.fork(f)
  ignore(rt.run_ready())
  match fiber.poll() {
    Some(Succeeded(v)) => v
    _ => abort("async test did not finish")
  }
}

///|
test "decision_models asks decision.resolvedModel only of profiles whose decision capability is ready" {
  let profiles : Array[Profile] = []
  let healths : Map[String, Health] = Map::new()
  for i in 0..<32 {
    let id = "p\{i}"
    profiles.push(test_profile(id, ["m-\{i}"]))
    let state = if i < 2 { "ready" } else { "none" }
    healths[id] = {
      check: Some(
        jobj([
          ("state", js("ok")),
          ("decision", jobj([("state", js(state)), ("models", jarr([js("m-\{i}")]))])),
        ]),
      ),
      quota: None,
      account: None,
      spent: false,
    }
  }
  let resolved_calls : Array[String] = []
  let models = accounts_ran(async fn() {
    decision_models_of(
      profiles,
      id => healths.get(id).unwrap_or(Health::empty()),
      async fn(raw, _cap, _model) {
        resolved_calls.push(js_string(raw.get("id")))
        jbool(true)
      },
      async fn(id) { js(id) },
    )
  })
  assert_eq(jitems(Some(models)).length(), 2)
  assert_eq(resolved_calls, ["p0", "p1"])
}

///|
fn test_profile(id : String, models : Array[String], billed? : Bool = false) -> Profile {
  let raw_fields = [
    ("id", js(id)),
    ("name", js(id)),
    ("runtime", js("claude")),
    ("models", jarr(models.map(js))),
    ("home", js("/homes/\{id}")),
  ]
  if billed {
    raw_fields.push(("kind", js("api")))
  }
  {
    raw: jobj(raw_fields),
    id,
    name: id,
    runtime: "claude",
    runtimes: ["claude"],
    models,
    named: models,
    model: models.get(0),
    home: "/homes/\{id}",
    enabled: true,
    machine: false,
    background_on_message: false,
    withheld: None,
  }
}

///|
test "pick_profile prefers paid usable accounts, skips spent/crowded, and resets expired windows" {
  let now = 1_800_000_000_000.0
  let p_api = test_profile("api", ["claude-opus-5-5"], billed=true)
  let p_spent = test_profile("spent", ["claude-opus-5-5"])
  let p_crowded = test_profile("crowded", ["claude-opus-5-5"])
  let p_reset = test_profile("reset", ["claude-opus-5-5"])
  let healths : Map[String, Health] = {
    "api": { check: Some(jobj([("state", js("ok"))])), quota: None, account: None, spent: false },
    "spent": { check: Some(jobj([("state", js("ok"))])), quota: None, account: None, spent: true },
    "crowded": {
      check: Some(jobj([("state", js("ok"))])),
      quota: Some(
        jobj([
          ("state", js("ok")),
          (
            "windows",
            jarr([
              jobj([("usedPercent", jnum(90.0)), ("minutes", jnum(300.0)), ("resetsAt", jnum(now + 3_600_000.0))]),
              jobj([("usedPercent", jnum(20.0)), ("minutes", jnum(10080.0)), ("resetsAt", jnum(now + 5.0 * 86_400_000.0))]),
            ]),
          ),
        ]),
      ),
      account: None,
      spent: false,
    },
    "reset": {
      check: Some(jobj([("state", js("ok"))])),
      quota: Some(
        jobj([
          ("state", js("ok")),
          (
            "windows",
            jarr([
              jobj([("usedPercent", jnum(100.0)), ("minutes", jnum(300.0)), ("resetsAt", jnum(now - 1000.0))]),
            ]),
          ),
        ]),
      ),
      account: None,
      spent: false,
    },
  }
  let signals : PoolSignals = {
    health: id => healths.get(id).unwrap_or(Health::empty()),
    load: _ => 0,
    last_picked: _ => 0.0,
    now: () => now,
  }
  // p_reset's 100% window already expired (resetsAt <= now), so it is usable, uncrowded, and paid
  assert_true(usable(healths["reset"], now~))
  assert_false(usable(healths["spent"], now~))
  let chosen = pick_profile([p_api, p_spent, p_crowded, p_reset], Some("claude-opus-5-5"), signals, true)
  assert_eq(chosen.id, "reset")
  // strict=true refuses when no profile serves the requested model; strict=false falls back
  assert_true((try Ok(pick_profile([p_api], Some("gpt-6-astra"), signals, true)) catch { e => Err(e) }) is Err(_))
  assert_eq(pick_profile([p_api], Some("gpt-6-astra"), signals, false).id, "api")
}

///|
test "cheap_to_leave and effort level intersection" {
  let points : Map[String, Double] = { "m": 200_000.0 }
  assert_true(cheap_to_leave([{ turn: jnum(1.0), profile: Some("p1"), model: Some("m"), context: Some(150_000.0) }], points))
  assert_false(cheap_to_leave([{ turn: jnum(1.0), profile: Some("p1"), model: Some("m"), context: Some(100_000.0) }], points))
  // Recent compaction (>50% drop from >=50k) on the same profile & model makes leaving cheap
  assert_true(
    cheap_to_leave(
      [
        { turn: jnum(1.0), profile: Some("p1"), model: Some("m"), context: Some(80_000.0) },
        { turn: jnum(2.0), profile: Some("p1"), model: Some("m"), context: Some(20_000.0) },
      ],
      Map::new(),
    ),
  )
  let catalog = jobj([("codex", jobj([("gpt-6-sol", jarr([js("low"), js("medium"), js("high")]))]))])
  assert_eq(available_efforts("codex", Some("gpt-6-sol"), Some(catalog)), ["low", "medium", "high"])
  assert_eq(common_efforts([["low", "medium", "high"], ["medium", "high", "xhigh"]], "codex"), ["medium", "high"])
}

///|
fn test_access_profile(id : String, models : Array[String], access : JV) -> Profile {
  let raw = jobj([
    ("id", js(id)),
    ("name", js(id)),
    ("runtime", js("claude")),
    ("models", jarr(models.map(js))),
    ("home", js("/homes/\{id}")),
    ("access", access),
  ])
  {
    raw,
    id,
    name: id,
    runtime: "claude",
    runtimes: ["claude"],
    models,
    named: models,
    model: models.get(0),
    home: "/homes/\{id}",
    enabled: true,
    machine: false,
    background_on_message: false,
    withheld: None,
  }
}

///|
test "choose_run_on_profile leaves billed-per-use immediately without cheap_to_leave, while crowded subscriptions still wait" {
  let now = 1_800_000_000_000.0
  let p_or = test_access_profile(
    "or",
    ["anthropic/claude-opus-5.5"],
    jobj([("kind", js("api-provider")), ("provider", js("openrouter")), ("key", js("k"))]),
  )
  let p_sub1 = test_access_profile("sub1", ["claude-opus-5-5"], jobj([("kind", js("subscription"))]))
  let p_sub2 = test_access_profile("sub2", ["claude-opus-5-5"], jobj([("kind", js("subscription"))]))
  let mut cur_profile = "or"
  let mut cur_pinned = false
  let mut recently_compacted = false
  let mut cur_profiles : Array[Profile] = [p_or, p_sub1]
  let healths : Map[String, Health] = {
    "or": { check: Some(jobj([("state", js("ok"))])), quota: None, account: None, spent: false },
    "sub1": {
      check: Some(jobj([("state", js("ok"))])),
      quota: Some(
        jobj([
          ("state", js("ok")),
          (
            "windows",
            jarr([
              jobj([("usedPercent", jnum(10.0)), ("minutes", jnum(300.0)), ("resetsAt", jnum(now + 3_600_000.0))]),
              jobj([("usedPercent", jnum(20.0)), ("minutes", jnum(10080.0)), ("resetsAt", jnum(now + 5.0 * 86_400_000.0))]),
            ]),
          ),
        ]),
      ),
      account: None,
      spent: false,
    },
    "sub2": {
      check: Some(jobj([("state", js("ok"))])),
      quota: Some(
        jobj([
          ("state", js("ok")),
          (
            "windows",
            jarr([
              jobj([("usedPercent", jnum(10.0)), ("minutes", jnum(300.0)), ("resetsAt", jnum(now + 3_600_000.0))]),
              jobj([("usedPercent", jnum(20.0)), ("minutes", jnum(10080.0)), ("resetsAt", jnum(now + 5.0 * 86_400_000.0))]),
            ]),
          ),
        ]),
      ),
      account: None,
      spent: false,
    },
  }
  let contexts : Array[ContextCall] = [
    { turn: js("t1"), profile: Some("or"), model: Some("claude-opus-5-5"), context: Some(60_000.0) },
    { turn: js("t1"), profile: Some("or"), model: Some("claude-opus-5-5"), context: Some(90_000.0) },
  ]
  // `run_on` as the hub drives it: the session's row, its profiles' health, and the profile it is moved to.
  let run_on = (holding : Bool) => accounts_ran(async fn() {
    let row = Row::of_jv(
      jobj([
        ("key", js("s1")),
        ("runtime", js("claude")),
        ("profile", js(cur_profile)),
        ("profilePinned", jbool(cur_pinned)),
        ("model", js("claude-opus-5-5")),
      ]),
    )
    let health = (id : String) => healths.get(id).unwrap_or(Health::empty())
    let choice = choose_run_on_profile(
      "s1",
      row,
      cur_profiles,
      holding,
      crowded=p => urgency(health(p.id).quota, now).crowded,
      can=id => usable(health(id), now~),
      health_of=health,
      cheap_to_leave=() => recently_compacted || cheap_to_leave(contexts, {}),
      elsewhere=() => None,
      pick=among => pick_profile(
        among,
        row.model,
        { health, load: _ => 0, last_picked: _ => 0.0, now: () => now },
        false,
      ),
    )
    match choice {
      Stay(p) => p
      Move(p) => {
        cur_profile = p.id
        p
      }
    }
  })
  // 1. On OpenRouter, holding=true stays on OpenRouter.
  let held = run_on(true)
  assert_eq(held.id, "or")
  assert_eq(cur_profile, "or")
  // 2. On OpenRouter, pinned=true stays on OpenRouter.
  cur_pinned = true
  let pinned = run_on(false)
  assert_eq(pinned.id, "or")
  assert_eq(cur_profile, "or")
  // 3. On OpenRouter, unpinned & not holding & NOT cheap_to_leave: moves to sub1 immediately.
  cur_pinned = false
  let moved = run_on(false)
  assert_eq(moved.id, "sub1")
  assert_eq(cur_profile, "sub1")
  // 4. Crowded paid subscription (sub1 5h=90%) with uncrowded sub2: stays on sub1 when cheap_to_leave is false.
  cur_profiles = [p_or, p_sub1, p_sub2]
  healths["sub1"] = {
    check: Some(jobj([("state", js("ok"))])),
    quota: Some(
      jobj([
        ("state", js("ok")),
        (
          "windows",
          jarr([
            jobj([("usedPercent", jnum(90.0)), ("minutes", jnum(300.0)), ("resetsAt", jnum(now + 3_600_000.0))]),
            jobj([("usedPercent", jnum(20.0)), ("minutes", jnum(10080.0)), ("resetsAt", jnum(now + 5.0 * 86_400_000.0))]),
          ]),
        ),
      ]),
    ),
    account: None,
    spent: false,
  }
  let stayed_crowded = run_on(false)
  assert_eq(stayed_crowded.id, "sub1")
  assert_eq(cur_profile, "sub1")
  // 5. Once cheap_to_leave is true, crowded subscription moves to sub2.
  recently_compacted = true
  let left_crowded = run_on(false)
  assert_eq(left_crowded.id, "sub2")
  assert_eq(cur_profile, "sub2")
  // 6. Crowded billed-per-use profile moving to another billed-per-use profile still waits for cheap_to_leave.
  let p_or2 = test_access_profile(
    "or2",
    ["anthropic/claude-opus-5.5"],
    jobj([("kind", js("api-provider")), ("provider", js("openrouter")), ("key", js("k2"))]),
  )
  cur_profiles = [p_or, p_or2]
  cur_profile = "or"
  recently_compacted = false
  healths["or"] = {
    check: Some(jobj([("state", js("ok"))])),
    quota: Some(
      jobj([
        ("state", js("ok")),
        (
          "windows",
          jarr([
            jobj([("usedPercent", jnum(90.0)), ("minutes", jnum(300.0)), ("resetsAt", jnum(now + 3_600_000.0))]),
            jobj([("usedPercent", jnum(20.0)), ("minutes", jnum(10080.0)), ("resetsAt", jnum(now + 5.0 * 86_400_000.0))]),
          ]),
        ),
      ]),
    ),
    account: None,
    spent: false,
  }
  healths["or2"] = {
    check: Some(jobj([("state", js("ok"))])),
    quota: Some(
      jobj([
        ("state", js("ok")),
        (
          "windows",
          jarr([
            jobj([("usedPercent", jnum(10.0)), ("minutes", jnum(300.0)), ("resetsAt", jnum(now + 3_600_000.0))]),
            jobj([("usedPercent", jnum(20.0)), ("minutes", jnum(10080.0)), ("resetsAt", jnum(now + 5.0 * 86_400_000.0))]),
          ]),
        ),
      ]),
    ),
    account: None,
    spent: false,
  }
  let stayed_or = run_on(false)
  assert_eq(stayed_or.id, "or")
  assert_eq(cur_profile, "or")
}

///|
test "signs_in skips blocked quota, pick_profile prefers healthy over unavailable, and choose_run_on_profile leaves unavailable immediately" {
  let now = 1_800_000_000_000.0
  let p_cc1 = test_access_profile("cc1", ["claude-opus-5-5"], jobj([("kind", js("subscription"))]))
  let p_cc2 = test_access_profile("cc2", ["claude-opus-5-5"], jobj([("kind", js("subscription"))]))
  let p_cc3 = test_access_profile("cc3", ["claude-opus-5-5"], jobj([("kind", js("subscription"))]))
  let p_key = test_access_profile("key", ["claude-opus-5-5"], jobj([("kind", js("anthropic-api")), ("key", js("k"))]))
  let unavail_q = jobj([
    ("state", js("unavailable")),
    ("windows", jarr([])),
    ("detail", js("Claude 登录续期请求失败，请稍后重试")),
  ])
  let blocked_q = jobj([
    ("state", js("blocked")),
    ("windows", jarr([])),
    ("detail", js("account suspended")),
  ])
  let ok_q = (five : Double, seven : Double) => jobj([
    ("state", js("ok")),
    (
      "windows",
      jarr([
        jobj([("usedPercent", jnum(five)), ("minutes", jnum(300.0)), ("resetsAt", jnum(now + 3_600_000.0))]),
        jobj([("usedPercent", jnum(seven)), ("minutes", jnum(10080.0)), ("resetsAt", jnum(now + 5.0 * 86_400_000.0))]),
      ]),
    ),
  ])
  let blocked_health : Health = { check: Some(jobj([("state", js("ok"))])), quota: Some(blocked_q), account: None, spent: false }
  assert_false(signs_in(blocked_health))
  assert_false(usable(blocked_health, now~))

  let healths : Map[String, Health] = {
    "cc1": { check: Some(jobj([("state", js("ok"))])), quota: Some(unavail_q), account: None, spent: false },
    "cc2": { check: Some(jobj([("state", js("ok"))])), quota: Some(ok_q(80.0, 50.0)), account: None, spent: false },
    "cc3": { check: Some(jobj([("state", js("ok"))])), quota: Some(ok_q(79.0, 50.0)), account: None, spent: false },
    "key": { check: Some(jobj([("state", js("ok"))])), quota: Some(jobj([("state", js("unsupported")), ("windows", jarr([]))])), account: None, spent: false },
  }
  let signals : PoolSignals = {
    health: id => healths.get(id).unwrap_or(Health::empty()),
    load: id => if id == "cc2" || id == "cc3" { 5 } else { 0 },
    last_picked: _ => 0.0,
    now: () => now,
  }
  // Healthy subscriptions beat unavailable cc1 even with higher load.
  let picked = pick_profile([p_cc1, p_cc2, p_cc3], Some("claude-opus-5-5"), signals, true)
  assert_true(picked.id == "cc2" || picked.id == "cc3")
  // When all other subscriptions are spent, check:ok + quota:unavailable subscription still beats pay-as-you-go.
  healths["cc2"] = { check: Some(jobj([("state", js("ok"))])), quota: Some(ok_q(100.0, 100.0)), account: None, spent: false }
  healths["cc3"] = { check: Some(jobj([("state", js("ok"))])), quota: Some(ok_q(100.0, 100.0)), account: None, spent: false }
  assert_eq(pick_profile([p_cc1, p_cc2, p_cc3, p_key], Some("claude-opus-5-5"), signals, true).id, "cc1")
  // Once cc1's check fails, pay-as-you-go takes over.
  healths["cc1"] = { check: Some(jobj([("state", js("failed"))])), quota: Some(unavail_q), account: None, spent: false }
  assert_eq(pick_profile([p_cc1, p_cc2, p_cc3, p_key], Some("claude-opus-5-5"), signals, true).id, "key")

  // choose_run_on_profile: leaves unavailable cc1 immediately without cheap_to_leave, respects holding/pinned,
  // and healthy crowded cc2 never moves onto unavailable cc1.
  healths["cc1"] = { check: Some(jobj([("state", js("ok"))])), quota: Some(unavail_q), account: None, spent: false }
  healths["cc2"] = { check: Some(jobj([("state", js("ok"))])), quota: Some(ok_q(85.0, 20.0)), account: None, spent: false }
  healths["cc3"] = { check: Some(jobj([("state", js("ok"))])), quota: Some(ok_q(20.0, 20.0)), account: None, spent: false }
  let health = (id : String) => healths.get(id).unwrap_or(Health::empty())
  let run_choice = (cur : String, pinned : Bool, holding : Bool, cheap : Bool, list : Array[Profile]) => accounts_ran(async fn() {
    let row = Row::of_jv(
      jobj([
        ("key", js("s1")),
        ("runtime", js("claude")),
        ("profile", js(cur)),
        ("profilePinned", jbool(pinned)),
        ("model", js("claude-opus-5-5")),
      ]),
    )
    match
      choose_run_on_profile(
        "s1",
        row,
        list,
        holding,
        crowded=p => urgency(health(p.id).quota, now).crowded,
        can=id => usable(health(id), now~),
        health_of=health,
        cheap_to_leave=() => cheap,
        elsewhere=() => None,
        pick=among => pick_profile(
          among,
          row.model,
          { health, load: _ => 0, last_picked: _ => 0.0, now: () => now },
          false,
        ),
      ) {
      Stay(p) => p.id
      Move(p) => p.id
    }
  })
  // Holding stays on unavailable cc1.
  assert_eq(run_choice("cc1", false, true, false, [p_cc1, p_cc3]), "cc1")
  // Pinned stays on unavailable cc1.
  assert_eq(run_choice("cc1", true, false, false, [p_cc1, p_cc3]), "cc1")
  // Unpinned & not holding & not cheap_to_leave: leaves unavailable cc1 immediately for healthy cc3.
  assert_eq(run_choice("cc1", false, false, false, [p_cc1, p_cc3]), "cc3")
  // Healthy crowded cc2 must never move onto unavailable cc1 even when cheap_to_leave is true.
  assert_eq(run_choice("cc2", false, false, true, [p_cc1, p_cc2]), "cc2")
}

///|
test "agy says where to verify an account Google holds until it is verified" {
  let page = "https://accounts.google.com/v3/signin/continue?plt=AKgnsb&continue=https://developers.google.com/x&sarp=1"
  assert_eq(
    agy_verify(
      "Eligibility check failed: Your current account is not eligible for Antigravity. Verify your account to continue.\n\nPlease verify your account in your browser to continue:\n\{page}",
    ),
    Some(page),
  )
  assert_eq(agy_verify("PERMISSION_DENIED (code 403): Verify your account to continue."), Some(""))
  assert_eq(agy_verify("Your account has been suspended"), None)
  assert_eq(
    agy_verify(
      "Eligibility check failed: Your current account is not eligible for Antigravity, because it is not currently available in your location.",
    ),
    None,
  )
}
