// What the package's own words are on values whose answers the TypeScript gave (the rest is held to the TypeScript
// itself by station/test/mb-accounts-pool.test.ts).

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
