// Whitebox tests for per-call `*-names.json` caching (`OutflowCache`) and `cost_cached`.

///|
test "outflow_person_with caches each book file once across 20 users and multiple connects" {
  let reads : Map[String, Int] = Map([])
  let slack_entries : Array[(String, @jsjson.JValue)] = []
  for i in 0..<20 {
    slack_entries.push(
      (
        "u:T1:U\{i}",
        @jsjson.JValue::Obj([
          (
            "person",
            @jsjson.JValue::Obj([
              ("name", @jsjson.JValue::Str("User \{i}")),
              ("email", @jsjson.JValue::Str("u\{i}@example.com")),
            ]),
          ),
        ]),
      ),
    )
  }
  // Duplicate key in JValue::Obj: first-wins must match JValue::get semantics.
  slack_entries.push(
    (
      "u:T1:Udup",
      @jsjson.JValue::Obj([
        ("person", @jsjson.JValue::Obj([("name", @jsjson.JValue::Str("First")), ("email", @jsjson.JValue::Str("first@example.com"))])),
      ]),
    ),
  )
  slack_entries.push(
    (
      "u:T1:Udup",
      @jsjson.JValue::Obj([
        ("person", @jsjson.JValue::Obj([("name", @jsjson.JValue::Str("Second")), ("email", @jsjson.JValue::Str("second@example.com"))])),
      ]),
    ),
  )
  // Lone surrogate vs literal U+FFFD stay distinct in UTF-16 MoonBit strings.
  let lone_str = String::from_array([Int::unsafe_to_char(0xD800)])
  let fffd_str = "\u{FFFD}"
  slack_entries.push(
    (
      "u:T1:\{lone_str}",
      @jsjson.JValue::Obj([
        ("person", @jsjson.JValue::Obj([("name", @jsjson.JValue::Str("Lone")), ("email", @jsjson.JValue::Str("lone@example.com"))])),
      ]),
    ),
  )
  slack_entries.push(
    (
      "u:T1:\{fffd_str}",
      @jsjson.JValue::Obj([
        ("person", @jsjson.JValue::Obj([("name", @jsjson.JValue::Str("FFFD")), ("email", @jsjson.JValue::Str("fffd@example.com"))])),
      ]),
    ),
  )
  let files : Map[String, @jsjson.JValue] = {
    "/data/remote-connects.json": @jsjson.parse("{\"c_remote\":{\"described\":{\"kind\":\"slack\",\"team\":\"T1\"}}}"),
    "/data/config.json": @jsjson.parse(
      "{\"connects\":[{\"id\":\"c1\",\"kind\":\"slack\",\"slack\":{\"team\":{\"id\":\"T1\"}}},{\"id\":\"c2\",\"kind\":\"slack\",\"slack\":{\"team\":{\"id\":\"T1\"}}},{\"id\":\"f1\",\"kind\":\"feishu\"},{\"id\":\"cm1\",\"kind\":\"comma\"}]}",
    ),
    "/data/slack-names.json": @jsjson.JValue::Obj(slack_entries),
    "/data/feishu-names.json": @jsjson.parse("{\"u:f1:F0\":{\"person\":{\"name\":\"Fei\",\"email\":\"fei@example.com\"}}}"),
    "/data/comma-names.json": @jsjson.JValue::Arr([]),
  }
  let read_fn : (String) -> @jsjson.JValue raise = (path : String) => {
    reads[path] = reads.get(path).unwrap_or(0) + 1
    files.get(path).unwrap_or(@jsjson.JValue::Obj([]))
  }
  let cache = OutflowCache::new()
  // 20 distinct Slack users across c1, c2, and c_remote all sharing slack-names.json
  for i in 0..<20 {
    let cid = if i % 3 == 0 { "c1" } else if i % 3 == 1 { "c2" } else { "c_remote" }
    let p = outflow_person_with(read_fn, "/data", "/", cache, "slack:\{cid}:U\{i}")
    assert_eq(p.value("name"), Some(Json::string("User \{i}")))
    assert_eq(p.value("email"), Some(Json::string("u\{i}@example.com")))
    assert_eq(p.value("via"), Some(Json::string("slack")))
  }
  // Duplicate key -> first-wins
  let dup = outflow_person_with(read_fn, "/data", "/", cache, "slack:c1:Udup")
  assert_eq(dup.value("name"), Some(Json::string("First")))
  assert_eq(dup.value("email"), Some(Json::string("first@example.com")))
  // Missing user -> name is null (matches suffix ":Umiss"), email null
  let miss = outflow_person_with(read_fn, "/data", "/", cache, "slack:c1:Umiss")
  assert_eq(miss.value("name"), Some(Json::null()))
  assert_eq(miss.value("email"), Some(Json::null()))
  assert_eq(miss.value("via"), Some(Json::string("slack")))
  // Lone surrogate vs U+FFFD
  let lone = outflow_person_with(read_fn, "/data", "/", cache, "slack:c1:\{lone_str}")
  assert_eq(lone.value("name"), Some(Json::string("Lone")))
  let fffd = outflow_person_with(read_fn, "/data", "/", cache, "slack:c1:\{fffd_str}")
  assert_eq(fffd.value("name"), Some(Json::string("FFFD")))
  // Different books: feishu (valid object) and comma (non-object array -> empty index)
  let fei = outflow_person_with(read_fn, "/data", "/", cache, "slack:f1:F0")
  assert_eq(fei.value("name"), Some(Json::string("Fei")))
  assert_eq(fei.value("via"), Some(Json::string("feishu")))
  let cm = outflow_person_with(read_fn, "/data", "/", cache, "slack:cm1:X1")
  assert_eq(cm.value("name"), Some(Json::null()))
  assert_eq(cm.value("via"), Some(Json::string("comma")))
  let _ = outflow_person_with(read_fn, "/data", "/", cache, "slack:cm1:X2")
  // Assert exact single read per file
  assert_eq(reads.get("/data/remote-connects.json"), Some(1))
  assert_eq(reads.get("/data/config.json"), Some(1))
  assert_eq(reads.get("/data/slack-names.json"), Some(1))
  assert_eq(reads.get("/data/feishu-names.json"), Some(1))
  assert_eq(reads.get("/data/comma-names.json"), Some(1))
}

///|
test "outflow_person_with propagates read errors without caching empty book" {
  let mut attempts = 0
  let read_fn = (path : String) => {
    if path == "/data/slack-names.json" {
      attempts += 1
      if attempts == 1 {
        raise Failure("io boom")
      }
      return @jsjson.parse("{\"u:?:U1\":{\"person\":{\"name\":\"Recovered\",\"email\":\"r@example.com\"}}}")
    }
    @jsjson.JValue::Obj([])
  }
  let cache = OutflowCache::new()
  let mut failed = false
  let _ = outflow_person_with(read_fn, "/data", "/", cache, "slack:c1:U1") catch {
    Failure(m) => {
      assert_eq(m, "io boom")
      failed = true
      Json::null()
    }
    _ => Json::null()
  }
  assert_true(failed)
  let p = outflow_person_with(read_fn, "/data", "/", cache, "slack:c1:U1")
  assert_eq(p.value("name"), Some(Json::string("Recovered")))
  assert_eq(attempts, 2)
}

///|
test "cost_cached matches cost across known, unknown, fast, and cache_write_long" {
  let cache : Map[String, Price?] = Map([])
  let models : Array[Json] = [
    Json::string("claude-opus-5-5"),
    Json::string("claude-opus-5-5"),
    Json::string("unknown-model-xyz"),
    Json::string("unknown-model-xyz"),
    Json::null(),
  ]
  for i, m in models {
    let g : Group = {
      day: "2026-11-25",
      session: Json::string("s1"),
      thread: Json::number(1.0),
      person: Json::null(),
      profile: Json::null(),
      runtime: Json::string("claude"),
      model: m,
      fast: i % 2 == 1,
      calls: 3.0,
      input: 12345.0,
      cache_read: 67890.0,
      cache_write: 1111.0,
      cache_write_long: 2222.0,
      output: 3333.0,
    }
    assert_eq(cost_cached(g, cache), cost(g))
  }
  assert_eq(cache.length(), 2)
}
