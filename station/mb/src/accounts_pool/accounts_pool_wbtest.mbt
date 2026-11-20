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
  let profiles = []
  let checks = []
  for i in 0..<32 {
    let id = "p\{i}"
    let runtime = if i % 2 == 0 { "claude" } else { "codex" }
    profiles.push(
      jobj([
        ("id", js(id)),
        ("name", js("Profile \{i}")),
        ("runtime", js(runtime)),
        ("models", jarr([js("m-\{i}")])),
        ("home", js("homes/\{id}")),
      ]),
    )
    let state = if i < 2 { "ready" } else { "none" }
    checks.push(
      jarr([
        js(id),
        jobj([
          (
            "check",
            jobj([
              ("state", js("ok")),
              ("decision", jobj([("state", js(state)), ("models", jarr([js("m-\{i}")]))])),
            ]),
          ),
        ]),
      ]),
    )
  }
  let raw = jobj([("profiles", jarr(profiles))])
  let resolved_calls : Array[String] = []
  let rt = @effect.Runtime::new()
  let b = Backend::new(async fn(name, args) {
    match name {
      "store.profileStatus" => jarr(checks)
      "decision.resolvedModel" => {
        resolved_calls.push(js_string(args.get(0).bind(p => p.get("id"))))
        jbool(true)
      }
      "modelName" => args.get(0).unwrap_or(Null)
      _ => Null
    }
  })
  let clock : Clock = { now: () => 1_800_000_000_000.0, after: (_, _) => () => () }
  let ctx : Ctx = {
    io: Io::new(b),
    words: Words::new(Obj([]), Obj([])),
    urls: Obj([]),
    station_lang: "en",
    tz_offset_ms: _ => 0.0,
  }
  let given = Given::of_jv(jobj([("checkOnStart", jbool(false))]), "/data")
  let acc = accounts_ran(async fn() {
    Accounts::new(b, ctx, given, rt, clock, raw, Catalog::new())
  })
  let models = accounts_ran(async fn() { acc.decision_models() })
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
