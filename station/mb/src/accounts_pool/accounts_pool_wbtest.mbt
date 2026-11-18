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
test "a profile made of its own entry is the one the whole config makes" {
  // (`Accounts::profile` makes only the entry asked; it must be what `hub_config` gives for that id)
  let raw = parse(
    #|{"profiles": [
    #|  {"id": "a", "name": " A ", "runtime": "claude", "models": ["claude-opus-5-5", "claude-opus-5-5"], "home": "homes/a"},
    #|  {"id": "b", "runtime": "codex", "models": ["gpt-6.2-sol"], "machine": true, "name": "B", "enabled": false},
    #|  {"id": "c", "runtimes": ["agy", "claude"], "withheld": ["x", ""], "backgroundOnMessage": false},
    #|  {"id": "a", "name": "second a"}
    #|]}
  ) catch {
    _ => abort("bad JSON")
  }
  let found = (id : String) => if id == "a" { Some(["claude-sonnet-5-5", "claude-opus-5-5"]) } else { None }
  let whole = hub_config(raw, "/data", found~).profiles
  for id in ["a", "b", "c"] {
    let mine = jitems(raw.get("profiles"))
      .iter()
      .find_first(p => js_string(p.get("id")) == id)
      .map(p => profile_of(p, "/data", found))
    let theirs = whole.iter().find_first(p => p.id == id)
    assert_eq(mine.map(p => stringify(p.raw)), theirs.map(p => stringify(p.raw)))
    assert_eq(mine.map(p => p.models), theirs.map(p => p.models))
    assert_eq(mine.map(p => p.name), theirs.map(p => p.name))
  }
}
