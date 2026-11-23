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
fn test_profile(
  id : String,
  models : Array[String],
  billed? : Bool = false,
  max_concurrent_sessions? : Int? = None,
  new_account_protection? : Bool = false,
) -> Profile {
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
  match max_concurrent_sessions {
    Some(n) => {
      raw_fields.push(("maxConcurrentSessions", jint(n)))
      if new_account_protection {
        raw_fields.push(("newAccountProtection", jbool(true)))
      }
    }
    None => ()
  }
  {
    raw: jobj(raw_fields),
    id,
    name: id,
    runtime: Some("claude"),
    service: None,
    runtimes: ["claude"],
    models,
    named: models,
    model: models.get(0),
    home: "/homes/\{id}",
    enabled: true,
    machine: false,
    background_on_message: false,
    withheld: None,
    max_concurrent_sessions,
    new_account_protection: new_account_protection && max_concurrent_sessions is Some(_),
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
    active: None,
    last_picked: _ => 0.0,
    now: () => now,
    max_sessions: None,
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
fn test_access_profile(
  id : String,
  models : Array[String],
  access : JV,
  max_concurrent_sessions? : Int? = None,
  new_account_protection? : Bool = false,
) -> Profile {
  let fields = [
    ("id", js(id)),
    ("name", js(id)),
    ("runtime", js("claude")),
    ("models", jarr(models.map(js))),
    ("home", js("/homes/\{id}")),
    ("access", access),
  ]
  match max_concurrent_sessions {
    Some(n) => {
      fields.push(("maxConcurrentSessions", jint(n)))
      if new_account_protection {
        fields.push(("newAccountProtection", jbool(true)))
      }
    }
    None => ()
  }
  let raw = jobj(fields)
  {
    raw,
    id,
    name: id,
    runtime: Some("claude"),
    service: None,
    runtimes: ["claude"],
    models,
    named: models,
    model: models.get(0),
    home: "/homes/\{id}",
    enabled: true,
    machine: false,
    background_on_message: false,
    withheld: None,
    max_concurrent_sessions,
    new_account_protection: new_account_protection && max_concurrent_sessions is Some(_),
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
        { health, load: _ => 0, active: None, max_sessions: None, last_picked: _ => 0.0, now: () => now },
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
    active: None,
    last_picked: _ => 0.0,
    now: () => now,
    max_sessions: None,
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
          { health, load: _ => 0, active: None, max_sessions: None, last_picked: _ => 0.0, now: () => now },
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

///|
test "pace_view adds each spend row to its profile's (hour, scope) as the linear scan it replaced did" {
  // hours out of order and repeated, -0 beside 0, a NaN hour (each its own entry), models counted against more than one
  // window, a profile not shown, and one with nothing spent
  // a row as the store reads it (every count there: one missing is NaN, and the row spends nothing)
  let row = (hour : String, profile : String, runtime : String, model : String, input : Int, output : Int, fast : Bool) => "{\"hour\":\{hour},\"profile\":\"\{profile}\",\"runtime\":\"\{runtime}\",\"model\":\"\{model}\",\"fast\":\{fast},\"input\":\{input},\"cacheRead\":0,\"cacheWrite\":0,\"cacheWriteLong\":0,\"output\":\{output}}"
  let rows = [
    row("5", "a", "claude", "claude-fable-5-2", 1000000, 0, false),
    row("3", "a", "claude", "claude-opus-5-5", 2000, 300, false),
    row("5", "a", "claude", "claude-fable-5-2", 0, 7, true),
    row("0", "b", "agy", "gemini-4-neon", 10, 0, false),
    row("-0", "b", "agy", "gemini-4-neon", 20, 0, false),
    row("\"x\"", "b", "agy", "argon", 30, 0, false),
    row("\"x\"", "b", "agy", "argon", 40, 0, false),
    row("3", "a", "claude", "claude-opus-5-5", 5000, 9, false),
    row("4", "b", "agy", "claude-opus-5-5", 11, 0, false),
    row("4", "hidden", "claude", "claude-opus-5-5", 11, 0, false),
    row("2", "c", "codex", "gpt-6.1-sol", 0, 0, false),
    row("4", "b", "agy", "claude-opus-5-5", 13, 0, false),
    row("1", "a", "claude", "claude-opus-5-5", 1, 1, false),
  ]
  let read = @jsjson.parse(
    "{\"quotas\":[{\"profile\":\"c\",\"hour\":1,\"at\":2,\"windows\":[]}],\"spend\":[" +
    rows.join(",") +
    "]}",
  )
  let view = pace_view(Catalog::new(), 6.0 * hour_ms, read, p => p != "hidden")
  inspect(
    @jsjson.stringify(view.get("profiles").unwrap_or(Null)),
    content=(
      #|{"c":{"quotas":[{"hour":1,"at":2,"windows":[]}],"spend":[]},"a":{"quotas":[],"spend":[{"hour":1,"scope":"","weight":0.000024},{"hour":3,"scope":"","weight":0.03418},{"hour":5,"scope":"","weight":8.00056},{"hour":5,"scope":"Fable","weight":8.00056}]},"b":{"quotas":[],"spend":[{"hour":null,"scope":"3p","weight":0.00003},{"hour":null,"scope":"3p","weight":0.00004},{"hour":0,"scope":"gemini","weight":0.00003},{"hour":4,"scope":"3p","weight":0.000096}]}}
    ),
  )
}

///|
test "service and non-runtime profiles keep runtime=None and validate against services registry" {
  let svc_raw = @jsjson.parse(
    "{\"id\":\"gpu-1\",\"home\":\"homes/gpu-1\",\"access\":{\"kind\":\"service\",\"service\":\"fake-gpu\"}}",
  )
  let svc = profile_of(svc_raw, "/data", _ => None)
  assert_eq(svc.runtime, None)
  assert_eq(svc.service, Some("fake-gpu"))
  assert_eq(svc.runtimes, [])
  assert_true(svc.raw.get("runtime") is None)

  let jev_raw = @jsjson.parse(
    "{\"id\":\"jev-1\",\"home\":\"homes/jev-1\",\"access\":{\"kind\":\"api-provider\",\"provider\":\"jev\",\"key\":\"k\"}}",
  )
  let jev = profile_of(jev_raw, "/data", _ => None)
  assert_eq(jev.runtime, None)
  assert_eq(jev.runtimes, [])
  assert_true(jev.raw.get("runtime") is None)

  let cfg = @jsjson.parse(
    "{\"profiles\":[{\"id\":\"gpu-1\",\"home\":\"homes/gpu-1\",\"access\":{\"kind\":\"service\",\"service\":\"fake-gpu\"}}]}",
  )
  check_config(Some(cfg), "/data", services=["fake-gpu"])
  // Default built-in services includes colab.
  let colab_cfg = @jsjson.parse(
    "{\"profiles\":[{\"id\":\"colab-1\",\"home\":\"homes/colab-1\",\"access\":{\"kind\":\"service\",\"service\":\"colab\"}}]}",
  )
  check_config(Some(colab_cfg), "/data")
  let unregistered = try {
    check_config(Some(cfg), "/data", services=[])
    false
  } catch {
    _ => true
  }
  assert_true(unregistered)
  let with_rt = @jsjson.parse(
    "{\"profiles\":[{\"id\":\"gpu-1\",\"home\":\"homes/gpu-1\",\"runtime\":\"claude\",\"access\":{\"kind\":\"service\",\"service\":\"fake-gpu\"}}]}",
  )
  let rejected_rt = try {
    check_config(Some(with_rt), "/data", services=["fake-gpu"])
    false
  } catch {
    _ => true
  }
  assert_true(rejected_rt)
}

///|
test "put_profile_runtime_and_access preserves access.service and omits runtime when editing a service profile" {
  let existing = @jsjson.parse(
    "{\"id\":\"gpu-1\",\"name\":\"GPU 1\",\"runtime\":\"claude\",\"access\":{\"kind\":\"service\",\"service\":\"fake-gpu\"}}",
  )
  let keep = existing.get("access")
  // Editing name/enabled/workspaces without re-sending access keeps access.service and strips runtime.
  let (rt, acc) = put_profile_runtime_and_access(
    Some(existing),
    None,
    None,
    keep,
    Some("service"),
    None,
    None,
    None,
    None,
    None,
  )
  assert_eq(rt, None)
  assert_eq(jstr(jget(acc, "kind")), Some("service"))
  assert_eq(jstr(jget(acc, "service")), Some("fake-gpu"))
  // Explicit access.service overrides kept service and still omits runtime.
  let new_access = @jsjson.parse("{\"kind\":\"service\",\"service\":\"other-svc\"}")
  let (rt2, acc2) = put_profile_runtime_and_access(
    Some(existing),
    Some(js("claude")),
    Some(new_access),
    keep,
    Some("service"),
    None,
    None,
    None,
    None,
    None,
  )
  assert_eq(rt2, None)
  assert_eq(jstr(jget(acc2, "service")), Some("other-svc"))
}

///|
test "clip_keeping_links clips plain text at most while keeping an http(s) link crossing the cut whole" {
  let plain = String::make(350, 'a')
  assert_eq(clip_keeping_links(plain, 300).length(), 300)
  assert_eq(clip_keeping_links("short", 300), "short")

  let prefix = String::make(270, 'x') + " "
  let https_url = "https://accounts.google.com/v3/signin/continue?plt=abc1234567890xyz&flow=verify"
  let msg = prefix + https_url + " trailing words after space"
  assert_eq(clip_keeping_links(msg, 300), prefix + https_url)

  let http_url = "http://example.com/verify/token-that-crosses-the-300-char-boundary"
  let msg_http = prefix + http_url + "\nnext line"
  assert_eq(clip_keeping_links(msg_http, 300), prefix + http_url)

  // A link already ended before the cut: normal 300-char clip applies.
  let early = "see https://example.com/ok " + String::make(320, 'b')
  assert_eq(clip_keeping_links(early, 300).length(), 300)
}

///|
test "maxConcurrentSessions: validation, parsing, is_session_capped, pick_profile pace cap and bucketing" {
  let now = 1_800_000_000_000.0
  // check_config accepts absent, null, 0, and positive integers; rejects negative, float, string.
  let ok_cfg = (v : JV?) => {
    let fields = [
      ("id", js("p1")),
      ("runtime", js("claude")),
      ("access", jobj([("kind", js("subscription"))])),
      ("home", js("homes/p1")),
    ]
    match v {
      Some(x) => fields.push(("maxConcurrentSessions", x))
      None => ()
    }
    jobj([("profiles", jarr([jobj(fields)]))])
  }
  let passes = (v : JV?) => try {
    check_config(Some(ok_cfg(v)), "/data")
    true
  } catch {
    _ => false
  }
  assert_true(passes(None))
  assert_true(passes(Some(Null)))
  assert_true(passes(Some(jint(0))))
  assert_true(passes(Some(jint(8))))
  assert_false(passes(Some(jint(-1))))
  assert_false(passes(Some(jnum(2.5))))
  assert_false(passes(Some(js("4"))))

  // profile_of parses positive integers only; 0 / absent -> None; newAccountProtection only when capped.
  let parsed_zero = profile_of(
    jobj([("id", js("p0")), ("runtime", js("claude")), ("home", js("h/p0")), ("maxConcurrentSessions", jint(0)), ("newAccountProtection", jbool(true))]),
    "/data",
    _ => None,
  )
  assert_eq(parsed_zero.max_concurrent_sessions, None)
  assert_false(parsed_zero.new_account_protection)
  let parsed_pos = profile_of(
    jobj([("id", js("p8")), ("runtime", js("claude")), ("home", js("h/p8")), ("maxConcurrentSessions", jint(8)), ("newAccountProtection", jbool(true))]),
    "/data",
    _ => None,
  )
  assert_eq(parsed_pos.max_concurrent_sessions, Some(8))
  assert_true(parsed_pos.new_account_protection)

  // is_session_capped: billed-per-use is never capped; subscription respects active >= cap.
  let p_legacy = test_access_profile("legacy", ["opus"], jobj([("kind", js("subscription"))]))
  let p_capped = test_access_profile(
    "capped",
    ["opus"],
    jobj([("kind", js("subscription"))]),
    max_concurrent_sessions=Some(2),
    new_account_protection=true,
  )
  let p_api = test_access_profile(
    "or",
    ["opus"],
    jobj([("kind", js("api-provider")), ("provider", js("openrouter")), ("key", js("k"))]),
    max_concurrent_sessions=Some(1),
  )
  assert_false(is_session_capped(p_legacy, p_legacy.max_concurrent_sessions, 100))
  assert_false(is_session_capped(p_capped, p_capped.max_concurrent_sessions, 1))
  assert_true(is_session_capped(p_capped, p_capped.max_concurrent_sessions, 2))
  assert_false(is_session_capped(p_api, p_api.max_concurrent_sessions, 10))

  // Capped subscription caps pace at 1.0 so near-expiry weekly window does not steal from legacy (pace 2.0).
  let q = (five : Double, week : Double, reset_days : Double) => jobj([
    ("state", js("ok")),
    (
      "windows",
      jarr([
        jobj([("usedPercent", jnum(five)), ("minutes", jnum(300.0)), ("resetsAt", jnum(now + 3.0 * hour_ms))]),
        jobj([("usedPercent", jnum(week)), ("minutes", jnum(10080.0)), ("resetsAt", jnum(now + reset_days * 24.0 * hour_ms))]),
      ]),
    ),
  ])
  let healths : Map[String, Health] = {
    "legacy": { check: Some(jobj([("state", js("ok"))])), quota: Some(q(10.0, 20.0, 2.8)), account: None, spent: false },
    "capped": { check: Some(jobj([("state", js("ok"))])), quota: Some(q(10.0, 20.0, 1.0)), account: None, spent: false },
    "or": { check: Some(jobj([("state", js("ok"))])), quota: None, account: None, spent: false },
  }
  let base_signals = (load : (String) -> Int, active : (String) -> Int) => (
    {
      health: id => healths.get(id).unwrap_or(Health::empty()),
      load,
      active: Some(active),
      last_picked: _ => 0.0,
      now: () => now,
      max_sessions: None,
    } : PoolSignals
  )
  assert_eq(pick_profile([p_legacy, p_capped], Some("opus"), base_signals(_ => 0, _ => 0), true).id, "legacy")
  // 4 warm processes (load=4) + 0 running (active=0) is NOT capped.
  assert_eq(
    pick_profile([p_capped, p_api], Some("opus"), base_signals(id => if id == "capped" { 4 } else { 0 }, _ => 0), true).id,
    "capped",
  )
  // When capped has active >= 2, legacy wins even with higher load; without legacy, capped still beats billed-per-use.
  assert_eq(
    pick_profile(
      [p_capped, p_legacy],
      Some("opus"),
      base_signals(id => if id == "legacy" { 10 } else { 2 }, id => if id == "legacy" { 10 } else { 2 }),
      true,
    ).id,
    "legacy",
  )
  assert_eq(
    pick_profile([p_capped, p_api], Some("opus"), base_signals(_ => 2, _ => 2), true).id,
    "capped",
  )
}

///|
test "choose_run_on_profile throws AccountCapError when only capped subscriptions remain and respects force_cap" {
  let p_capped = test_access_profile(
    "capped",
    ["opus"],
    jobj([("kind", js("subscription"))]),
    max_concurrent_sessions=Some(2),
    new_account_protection=true,
  )
  let p_or = test_access_profile(
    "or",
    ["opus"],
    jobj([("kind", js("api-provider")), ("provider", js("openrouter")), ("key", js("k"))]),
  )
  let ok_h : Health = { check: Some(jobj([("state", js("ok"))])), quota: None, account: None, spent: false }
  let row = Row::of_jv(
    jobj([("key", js("s3")), ("runtime", js("claude")), ("profile", js("capped")), ("profilePinned", jbool(false)), ("model", js("opus"))]),
  )
  // With active=2 == cap=2 and force_cap=false, throws AccountCapError instead of falling back to OpenRouter.
  let threw_cap = accounts_ran(async fn() {
    try {
      ignore(
        choose_run_on_profile(
          "s3",
          row,
          [p_capped, p_or],
          false,
          force_cap=false,
          active_of=p => if p.id == "capped" { 2 } else { 0 },
          cap_of=p => p.max_concurrent_sessions,
          protection_of=p => p.new_account_protection,
          crowded=_ => false,
          can=_ => true,
          health_of=_ => ok_h,
          cheap_to_leave=async fn() { false },
          elsewhere=async fn() { None },
          elsewhere_paid=Some(async fn() { None }),
          pick=async fn(among) { among[0] },
        ),
      )
      false
    } catch {
      Thrown("AccountCapError", said) => said.get("protection") == Some(Bool(true))
      _ => false
    }
  })
  assert_true(threw_cap)
  // With force_cap=true (manual jump-the-queue), succeeds and stays on capped.
  let forced = accounts_ran(async fn() {
    match
      choose_run_on_profile(
        "s3",
        row,
        [p_capped, p_or],
        false,
        force_cap=true,
        active_of=p => if p.id == "capped" { 2 } else { 0 },
        cap_of=p => p.max_concurrent_sessions,
        crowded=_ => false,
        can=_ => true,
        health_of=_ => ok_h,
        cheap_to_leave=async fn() { false },
        elsewhere=async fn() { None },
        elsewhere_paid=Some(async fn() { None }),
        pick=async fn(among) { among[0] },
      ) {
      Stay(p) | Move(p) => p.id
    }
  })
  assert_eq(forced, "capped")
}

///|
test "a profile's home joined as paths.ts joinPath joins it" {
  assert_eq(join_under("/", "/data", "homes/p1"), "/data/homes/p1")
  assert_eq(join_under("/", "/data/", "homes/p1"), "/data/homes/p1")
  assert_eq(join_under("/", "", "homes/p1"), "homes/p1")
  assert_eq(join_under("/", "/data", "/data/homes/p1"), "/data/homes/p1")
  assert_eq(join_under("/", "/data", ""), "/data/")
  assert_eq(join_under("\\", "C:\\data", "homes\\p1"), "C:\\data\\homes\\p1")
  assert_eq(join_under("\\", "C:\\data\\", "homes\\p1"), "C:\\data\\homes\\p1")
  assert_eq(join_under("\\", "C:\\data/", "homes\\p1"), "C:\\data/homes\\p1")
  assert_eq(join_under("\\", "", "homes\\p1"), "homes\\p1")
  assert_eq(join_under("\\", "C:\\data", "C:\\data\\homes\\p1"), "C:\\data\\homes\\p1")
  assert_eq(join_under("\\", "C:\\data", "\\\\srv\\share\\h"), "\\\\srv\\share\\h")
  assert_eq(join_under("\\", "C:\\data", "/abs"), "/abs")
}

///|
test "borrowed_failure_stands keeps previous ok within grace, resets on recovery, and respects stands=false and codexRevoked" {
  let prev_ok = jobj([
    ("state", js("ok")),
    ("detail", js("host ok")),
    ("models", jarr([js("gemini-4-neon")])),
    ("modelEfforts", jobj([("agy", jobj([("gemini-4-neon", jarr([js("medium"), js("high")]))]))])),
    ("modelEffortDefaults", jobj([("agy", jobj([("gemini-4-neon", js("medium"))]))])),
  ])
  let since : Map[String, Double] = Map::new()
  // Within 10 min grace: keeps previous ok.
  assert_true(borrowed_failure_stands(true, Some(prev_ok), since, "ba", 1000.0) is Some(_))
  assert_true(borrowed_failure_stands(true, Some(prev_ok), since, "ba", 1000.0 + 300_000.0) is Some(_))
  // Recovery clears since; next outage gets a full 10 min window.
  since.remove("ba")
  assert_true(borrowed_failure_stands(true, Some(prev_ok), since, "ba", 1000.0 + 400_000.0) is Some(_))
  assert_true(borrowed_failure_stands(true, Some(prev_ok), since, "ba", 1000.0 + 400_000.0 + 599_999.0) is Some(_))
  // At or past 10 min grace: no longer stands.
  assert_true(borrowed_failure_stands(true, Some(prev_ok), since, "ba", 1000.0 + 400_000.0 + 600_000.0) is None)
  // Manual check (stands=false) never uses grace.
  since.remove("ba")
  assert_true(borrowed_failure_stands(false, Some(prev_ok), since, "ba", 1000.0) is None)
  // codexRevoked or non-ok previous never uses grace.
  let revoked = jset(prev_ok, "codexRevoked", jbool(true))
  assert_true(borrowed_failure_stands(true, Some(revoked), since, "ba", 1000.0) is None)
  let failed_prev = jobj([("state", js("failed")), ("models", Null)])
  assert_true(borrowed_failure_stands(true, Some(failed_prev), since, "ba", 1000.0) is None)
}

///|
test "preserve_check_metadata keeps models and effort capabilities when borrowed check fails" {
  let prev = jobj([
    ("state", js("ok")),
    ("models", jarr([js("gemini-4-neon"), js("gemini-4-pro")])),
    ("modelEfforts", jobj([("agy", jobj([("gemini-4-neon", jarr([js("medium"), js("high")]))]))])),
    ("modelEffortDefaults", jobj([("agy", jobj([("gemini-4-neon", js("medium"))]))])),
    ("codexUltrafastModels", jarr([js("gpt-6")])),
    ("fusion", jbool(true)),
  ])
  let failed = jobj([
    ("state", js("failed")),
    ("detail", js("host offline")),
    ("models", Null),
    ("checkedAt", jint(0)),
  ])
  let kept = preserve_check_metadata(failed, Some(prev))
  assert_true(kept.get("state") == Some(Str("failed")))
  assert_true(kept.get("models") == prev.get("models"))
  assert_true(kept.get("modelEfforts") == prev.get("modelEfforts"))
  assert_true(kept.get("modelEffortDefaults") == prev.get("modelEffortDefaults"))
  assert_true(kept.get("codexUltrafastModels") == prev.get("codexUltrafastModels"))
  assert_true(kept.get("fusion") == prev.get("fusion"))
}

///|
test "quota_ok_should_recheck covers all non-codex subscriptions (agy, claude, cursor, grok)" {
  assert_true(quota_ok_should_recheck(Some("agy"), false, "subscription", Some(Str("ok")), Some(Str("failed"))))
  assert_true(quota_ok_should_recheck(Some("agy"), false, "subscription", Some(Str("ok")), Some(Str("login"))))
  assert_true(quota_ok_should_recheck(Some("claude"), false, "subscription", Some(Str("ok")), Some(Str("failed"))))
  assert_true(quota_ok_should_recheck(Some("cursor"), false, "subscription", Some(Str("ok")), Some(Str("failed"))))
  assert_true(quota_ok_should_recheck(Some("grok"), false, "subscription", Some(Str("ok")), Some(Str("failed"))))
  assert_false(quota_ok_should_recheck(Some("codex"), false, "subscription", Some(Str("ok")), Some(Str("failed"))))
  assert_true(quota_ok_should_recheck(Some("codex"), true, "subscription", Some(Str("ok")), Some(Str("failed"))))
  assert_false(quota_ok_should_recheck(Some("agy"), false, "api-provider", Some(Str("ok")), Some(Str("failed"))))
  assert_false(quota_ok_should_recheck(Some("agy"), false, "subscription", Some(Str("ok")), Some(Str("ok"))))
}

///|
test "agy direct quota User-Agent carries the CLI product segment and skips production on daily failure" {
  assert_eq(agy_user_agent, "antigravity/cli/1.5.15")
  let daily = agy_cloud_code_url
  let prod = agy_production_url
  let weekly = quota_window("每周 · Gemini", 32.0, None, Some(week_minutes), scope="gemini")
  assert_false(should_fallback_gemini_weekly(None, [], daily, prod))
  assert_false(should_fallback_gemini_weekly(Some(Null), [], daily, prod))
  assert_true(should_fallback_gemini_weekly(Some(jobj([])), [], daily, prod))
  assert_false(should_fallback_gemini_weekly(Some(jobj([])), [weekly], daily, prod))
  assert_false(should_fallback_gemini_weekly(Some(jobj([])), [], daily, daily))
}

///|
test "MiniMax Token Plan and GLM Coding Plan windows, as quota.ts reads them" {
  let start = 1_800_000_000_000.0
  let end = start + 5.0 * 60.0 * 60_000.0
  let weekly_end = start + 7.0 * 24.0 * 60.0 * 60_000.0
  let when = (v : JV?) => match v {
    Some(Num(n)) => Some(n)
    _ => None
  }
  let general = jobj([
    ("model_name", js("general")),
    ("start_time", jnum(start)),
    ("end_time", jnum(end)),
    ("current_interval_remaining_percent", jnum(75.0)),
    ("weekly_start_time", jnum(start)),
    ("weekly_end_time", jnum(weekly_end)),
    ("current_weekly_remaining_percent", jnum(95.0)),
  ])
  let video = jobj([
    ("model_name", js("video")),
    ("current_interval_remaining_percent", jnum(10.0)),
    ("start_time", jnum(start)),
    ("end_time", jnum(end)),
  ])
  let minimax = (code : Double) => Some(
    jobj([
      ("base_resp", jobj([("status_code", jnum(code))])),
      ("model_remains", jarr([video, general])),
    ]),
  )
  assert_true(minimax_windows(minimax(0.0), when) == [
    quota_window("5 小时", 25.0, Some(end), Some(300.0)),
    quota_window("每周", 5.0, Some(weekly_end), Some(10080.0)),
  ])
  assert_true(minimax_windows(minimax(1004.0), when).is_empty())
  assert_true(minimax_windows(None, when).is_empty())
  let limit = (kind : String, unit : Double, number : Double, used : Double, reset : Double?) => {
    let fields = [
      ("type", js(kind)),
      ("unit", jnum(unit)),
      ("number", jnum(number)),
      ("percentage", jnum(used)),
    ]
    if reset is Some(r) {
      fields.push(("nextResetTime", jnum(r)))
    }
    jobj(fields)
  }
  let glm = (code : Double) => Some(
    jobj([
      ("code", jnum(code)),
      (
        "data",
        jobj([
          (
            "limits",
            jarr([
              limit("TOKENS_LIMIT", 6.0, 1.0, 11.0, Some(start)),
              limit("TOKENS_LIMIT", 3.0, 5.0, 0.0, None),
              limit("TIME_LIMIT", 5.0, 1.0, 37.0, Some(start)),
            ]),
          ),
        ]),
      ),
    ]),
  )
  assert_true(glm_coding_windows(glm(200.0), when) == [
    quota_window("5 小时", 0.0, None, Some(300.0)),
    quota_window("每周", 11.0, Some(start), Some(10080.0)),
  ])
  assert_true(glm_coding_windows(glm(401.0), when).is_empty())
}

///|
test "choose_run_on_profile takes a Google Vertex AI session back to a subscription refilled, added, or another runtime's" {
  let now = 1_800_000_000_000.0
  let model = "gemini-4-neon"
  let p_vx = test_access_profile(
    "vx",
    [model],
    jobj([("kind", js("api-provider")), ("provider", js("google-vertex")), ("key", js("{}"))]),
  )
  let p_ag = test_access_profile("ag", [model], jobj([("kind", js("subscription"))]))
  let p_ag2 = test_access_profile("ag2", [model], jobj([("kind", js("subscription"))]))
  let p_cc = test_access_profile("cc", [model], jobj([("kind", js("subscription"))]))
  let ok = Some(jobj([("state", js("ok"))]))
  let healths : Map[String, Health] = {
    "vx": { check: ok, quota: None, account: None, spent: false },
    "ag": { check: ok, quota: None, account: None, spent: true },
    "ag2": { check: ok, quota: None, account: None, spent: false },
  }
  let mut cur_profile = "vx"
  let mut cur_profiles : Array[Profile] = [p_ag, p_vx]
  let mut other_runtime : Profile? = None
  let mut asked_elsewhere = 0
  let run_on = (holding : Bool) => accounts_ran(async fn() {
    let row = Row::of_jv(
      jobj([
        ("key", js("s1")),
        ("runtime", js("agy")),
        ("profile", js(cur_profile)),
        ("profilePinned", jbool(false)),
        ("model", js(model)),
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
      cheap_to_leave=() => false,
      elsewhere=() => None,
      upgrade_elsewhere_paid=Some(async fn() {
        asked_elsewhere += 1
        other_runtime
      }),
      pick=among => pick_profile(
        among,
        row.model,
        { health, load: _ => 0, active: None, max_sessions: None, last_picked: _ => 0.0, now: () => now },
        false,
      ),
    )
    match choice {
      Stay(p) => {
        cur_profile = p.id
        p
      }
      Move(p) => {
        cur_profile = p.id
        p
      }
    }
  })
  // 1. Its subscription spent and none elsewhere: it stays on Vertex.
  assert_eq(run_on(false).id, "vx")
  assert_eq(asked_elsewhere, 1)
  // 2. Holding work in the background, another runtime's subscription is not asked for.
  other_runtime = Some(p_cc)
  assert_eq(run_on(true).id, "vx")
  assert_eq(asked_elsewhere, 1)
  // 3. Not holding: back to another runtime's subscription at once (no cheap_to_leave).
  assert_eq(run_on(false).id, "cc")
  assert_eq(asked_elsewhere, 2)
  // 4. Its own runtime's subscription refilled: there, another runtime's not asked for.
  cur_profile = "vx"
  healths["ag"] = { check: ok, quota: None, account: None, spent: false }
  assert_eq(run_on(false).id, "ag")
  assert_eq(asked_elsewhere, 2)
  // 5. Its subscription spent again, another of its runtime's added: there.
  cur_profile = "vx"
  healths["ag"] = { check: ok, quota: None, account: None, spent: true }
  cur_profiles = [p_ag, p_vx, p_ag2]
  assert_eq(run_on(false).id, "ag2")
  assert_eq(asked_elsewhere, 2)
  // 6. On a subscription, another runtime's is never asked for.
  assert_eq(run_on(false).id, "ag2")
  assert_eq(asked_elsewhere, 2)
}
